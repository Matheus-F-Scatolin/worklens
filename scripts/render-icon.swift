// Renders every image Worklens ships, from `WorklensMark` and nothing else.
//
// Not part of the package: `scripts/render-icon.sh` compiles this file together with
// `Sources/WorklensCore/UI/WorklensMark.swift`, so the icon and the menu bar cannot drift
// apart, and rendering needs no package build. CoreGraphics + ImageIO only, which is all the
// Command Line Tools toolchain has.
//
// Outputs, all relative to the repo root given as the first argument:
//   Resources/AppIcon.iconset/*.png   the ten tiles `iconutil` packs into AppIcon.icns
//   docs/media/social-preview.png     the 1280×640 card GitHub unfurls a link with
//   build/icon-preview/                previews, never committed (build/ is gitignored):
//     concept-*.png                    the three directions, for the owner to judge
//     contact-sheet.png                the icon and every menu-bar state at 1x and 2x,
//                                      light and dark, magnified with interpolation off
//     candidates/{A,B}/                the two container candidates at five sizes, which is
//                                      what the owner judges in a real Dock
//     glyph-*.png                      the menu-bar glyphs as loose files, at true size
//
// `--banner` renders the social card and nothing else, which is the fast path while the
// wording is being settled; a full run always renders it too, so the card and the icon are
// never one release apart. `--candidates` renders the two icon candidates alone.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct RenderIcon {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        let bannerOnly = arguments.contains("--banner")
        let candidatesOnly = arguments.contains("--candidates")
        let root = URL(fileURLWithPath:
            arguments.first(where: { !$0.hasPrefix("--") }) ?? ".")

        if candidatesOnly {
            writeCandidates(root)
            return
        }

        let media = root.appendingPathComponent("docs/media")
        write(banner(), to: media.appendingPathComponent("social-preview.png"))
        if bannerOnly {
            print("rendered docs/media/social-preview.png")
            return
        }
        writeCandidates(root)

        // The ten tiles `iconutil` expects, by the names it expects. Each is drawn at its own
        // size rather than downsampled from the 1024 master: vector art scaled by sips loses
        // the ring's edge at 16 px, and drawing it again is free.
        let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
        for base in [16, 32, 128, 256, 512] {
            write(icon(WorklensMark.chosen, pixels: base),
                  to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
            write(icon(WorklensMark.chosen, pixels: base * 2),
                  to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }

        let preview = root.appendingPathComponent("build/icon-preview")
        for concept in WorklensMark.Concept.allCases {
            write(icon(concept, pixels: 512),
                  to: preview.appendingPathComponent("concept-\(concept.rawValue).png"))
        }

        let onePoint = Int(WorklensMark.glyphDesignSize)
        for badge in WorklensMark.Badge.allCases {
            write(glyph(badge, pixels: onePoint, ink: 0),
                  to: preview.appendingPathComponent("glyph-\(badge.rawValue)@1x.png"))
            write(glyph(badge, pixels: onePoint * 2, ink: 0),
                  to: preview.appendingPathComponent("glyph-\(badge.rawValue)@2x.png"))
        }
        write(contactSheet(onePoint: onePoint),
              to: preview.appendingPathComponent("contact-sheet.png"))

        print("rendered \(WorklensMark.chosen.rawValue) → Resources/AppIcon.iconset, "
              + "docs/media/social-preview.png, build/icon-preview")
    }

    // MARK: - The two container candidates

    /// A and B at the five sizes the Dock, the Finder, the notification banner and the menu
    /// bar actually draw an icon at. Whether a legacy `.icns` gets the system's own container
    /// on macOS 26 is not answerable from here, so both are rendered and the Dock decides.
    static let candidateSizes = [1024, 512, 128, 32, 16]

    static func writeCandidates(_ root: URL) {
        let folder = root.appendingPathComponent("build/icon-preview/candidates")
        for (letter, container) in [("A", WorklensMark.Container.fullBleed),
                                    ("B", WorklensMark.Container.dockSafe)] {
            for pixels in candidateSizes {
                write(icon(WorklensMark.chosen, container: container, pixels: pixels),
                      to: folder.appendingPathComponent("\(letter)/icon-\(pixels).png"))
            }
        }
        print("rendered build/icon-preview/candidates/{A,B}/icon-{1024,512,128,32,16}.png")
    }

    // MARK: - The social card

    /// GitHub's social preview is 1280×640 and is shown small, so this is one mark, one word
    /// and two lines — the same ivory gradient as the icon tile, and `WorklensMark.drawMark`
    /// for the lens, so the card cannot say one thing while the icon says another.
    static func banner() -> CGImage {
        let width = 1280
        let height = 640
        let ctx = context(width, height)

        // Top to bottom, exactly like the icon tile — the same `WorklensMark.tileGradient()`,
        // not a second copy of its stops — and, incidentally, the cheapest thing a PNG can
        // store: every row of the background is identical to the one above it, which is what
        // keeps a 1280×640 card inside the media budget.
        ctx.drawLinearGradient(
            WorklensMark.tileGradient(),
            start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0),
            options: []
        )

        // The mark, large, on the right; the words on the left.
        ctx.saveGState()
        ctx.setFillColor(WorklensMark.Palette.terracotta)
        ctx.setStrokeColor(WorklensMark.Palette.terracotta)
        ctx.translateBy(x: 852, y: 150)
        WorklensMark.drawMark(in: ctx, pixels: 330)
        ctx.restoreGState()

        let ink = WorklensMark.Palette.ink
        let dimmed = WorklensMark.Palette.ink.copy(alpha: 0.80)!
        let faint = WorklensMark.Palette.muted
        text("Worklens", font(104, bold: true), ink, at: CGPoint(x: 110, y: 356), in: ctx)
        text(
            "Where your day actually went —",
            font(38, bold: false), dimmed, at: CGPoint(x: 114, y: 272), in: ctx
        )
        text(
            "and which parts a machine could have done.",
            font(38, bold: false), dimmed, at: CGPoint(x: 114, y: 220), in: ctx
        )
        text(
            "A macOS menu-bar app  ·  your own API keys  ·  one folder on your Mac",
            font(25, bold: false), faint, at: CGPoint(x: 116, y: 152), in: ctx
        )
        return ctx.makeImage()!
    }

    /// The system UI font, because the card should look like the app's own menu.
    static func font(_ size: CGFloat, bold: Bool) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard bold else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold)
            ?? base
    }

    static func text(
        _ string: String, _ font: CTFont, _ color: CGColor, at point: CGPoint, in ctx: CGContext
    ) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font, kCTForegroundColorAttributeName: color,
        ]
        let attributed = CFAttributedStringCreate(
            nil, string as CFString, attributes as CFDictionary
        )!
        ctx.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
    }

    // MARK: - Drawing

    static func icon(
        _ concept: WorklensMark.Concept,
        container: WorklensMark.Container = WorklensMark.shippedContainer,
        pixels: Int
    ) -> CGImage {
        let ctx = context(pixels, pixels)
        WorklensMark.drawAppIcon(concept, container: container, in: ctx, pixels: CGFloat(pixels))
        return ctx.makeImage()!
    }

    static func glyph(_ badge: WorklensMark.Badge, pixels: Int, ink: CGFloat) -> CGImage {
        let ctx = context(pixels, pixels)
        ctx.setFillColor(gray: ink, alpha: 1)
        ctx.setStrokeColor(gray: ink, alpha: 1)
        WorklensMark.drawGlyph(badge, in: ctx, size: CGFloat(pixels))
        return ctx.makeImage()!
    }

    /// The whole family in one image: the shipped app icon across the top at the sizes it is
    /// drawn at, then every badge across, and down the rows 1x then 2x, on a light menu bar
    /// then a dark one. Magnified with interpolation off, so what you are judging is the
    /// pixels the menu bar will actually light up — not a smoothed idea of them.
    static func contactSheet(onePoint: Int) -> CGImage {
        let magnification = 6
        let cell = onePoint * magnification
        let padding = 10
        let columns = WorklensMark.Badge.allCases.count
        let width = columns * (cell + padding) + padding
        let rows: [(background: CGFloat, ink: CGFloat, scale: Int)] = [
            (0.96, 0, 1), (0.96, 0, 2), (0.16, 1, 1), (0.16, 1, 2),
        ]
        let iconSizes = [128, 64, 32, 16]
        let band = 128 + padding * 2
        let height = rows.count * (cell + padding) + padding + band
        let sheet = context(width, height)
        sheet.interpolationQuality = .none
        sheet.setShouldAntialias(false)

        // The icon band sits above the glyph rows, on its own light ground.
        sheet.setFillColor(gray: 0.88, alpha: 1)
        sheet.fill(CGRect(x: 0, y: height - band, width: width, height: band))
        var iconX = padding
        for pixels in iconSizes {
            let image = icon(WorklensMark.chosen, pixels: pixels)
            sheet.interpolationQuality = .high
            sheet.draw(image, in: CGRect(
                x: iconX, y: height - padding - 128, width: 128, height: 128
            ))
            sheet.interpolationQuality = .none
            iconX += 128 + padding
        }

        // Row 0 is the first glyph row, and CoreGraphics counts from the bottom.
        for (index, row) in rows.enumerated() {
            let y = height - band - (index + 1) * (cell + padding)
            sheet.setFillColor(gray: row.background, alpha: 1)
            sheet.fill(CGRect(x: 0, y: y - padding / 2, width: width, height: cell + padding))
            for (column, badge) in WorklensMark.Badge.allCases.enumerated() {
                let x = padding + column * (cell + padding)
                let image = glyph(badge, pixels: onePoint * row.scale, ink: row.ink)
                sheet.draw(image, in: CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return sheet.makeImage()!
    }

    // MARK: - Bitmaps

    static func context(_ width: Int, _ height: Int) -> CGContext {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("could not make a \(width)×\(height) bitmap") }
        return ctx
    }

    static func write(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { fatalError("could not write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("could not finalize \(url.path)")
        }
    }
}
