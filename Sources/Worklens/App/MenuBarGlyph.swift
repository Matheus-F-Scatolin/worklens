import AppKit
import WorklensCore

/// The menu-bar icon, drawn rather than fetched.
///
/// `WorklensMark` defines one ring and seven things that sit inside it; this turns each into an
/// 18 pt template `NSImage`, which is the size AppKit gives a status item and the form that
/// lets macOS tint it — black on a light menu bar, white on a dark one, inverted while the menu
/// is open, and legible with Increase contrast on, none of which a coloured image gets right.
///
/// Drawn once per state and kept: `render()` runs on every counter refresh, and redrawing
/// seven bitmaps a minute for an icon that changes a few times a day would be silly.
@MainActor
enum MenuBarGlyph {
    /// #252: keyed on the state *and* the busy treatment, because busy no longer replaces the
    /// state — a paused app writing a report is two facts, and the cache has to hold both or
    /// the second one has nowhere to live.
    private struct Key: Hashable {
        let icon: MenuIcon
        let busy: Bool
    }

    private static var cache: [Key: NSImage] = [:]

    /// Nil when drawing failed, which is the caller's cue to fall back to `icon.rawValue`.
    static func image(for icon: MenuIcon, busy: Bool = false) -> NSImage? {
        let key = Key(icon: icon, busy: busy)
        if let cached = cache[key] { return cached }
        guard let drawn = draw(icon, busy: busy) else { return nil }
        cache[key] = drawn
        return drawn
    }

    private static func draw(_ icon: MenuIcon, busy: Bool) -> NSImage? {
        let side = WorklensMark.glyphDesignSize
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Opaque black: a template image's alpha channel is the shape, and the colour is
            // macOS's to choose.
            ctx.setFillColor(.black)
            ctx.setStrokeColor(.black)
            WorklensMark.drawGlyph(icon.badge, busy: busy, in: ctx, size: side)
            return true
        }
        image.isTemplate = true
        // A blank square in the menu bar is worse than the wrong symbol, so make it draw once
        // here where the failure can still be answered with the SF Symbol.
        var bounds = CGRect(origin: .zero, size: image.size)
        guard image.cgImage(forProposedRect: &bounds, context: nil, hints: nil) != nil else {
            return nil
        }
        return image
    }
}

/// The Dock/alert icon for a build that is not in a bundle.
///
/// `swift run Worklens` and `.build/release/Worklens` have no `Info.plist`, so every `NSAlert`
/// and every notification a dev build raises carries the generic executable glyph. The checkout
/// has the rendered `.icns` sitting right there; use it. A bundled app already has its own and
/// is left alone, and a binary copied away from its checkout finds nothing and keeps the
/// placeholder — this is a convenience, never a requirement.
@MainActor
enum DevAppIcon {
    static func applyWhenUnbundled() {
        guard Bundle.main.infoDictionary?["CFBundleIconFile"] == nil else { return }
        guard let url = checkoutIcon(), let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }

    /// `#filePath` is this file inside the checkout, which is the only reliable way back to the
    /// repo root from a binary LaunchServices gave a working directory of `/`. The binary's own
    /// location is tried too, for a `.build` directory that was moved with its checkout.
    private static func checkoutIcon() -> URL? {
        for start in [URL(fileURLWithPath: #filePath), Bundle.main.bundleURL] {
            var directory = start.deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("Resources/AppIcon.icns")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }
}
