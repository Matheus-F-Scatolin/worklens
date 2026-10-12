import ArgumentParser
import WorklensCore

/// `worklens app` — the menu bar, under a name that says so.
///
/// Issue #15 made a plain `worklens run` equivalent to launching the app, and #158 overrides that
/// without taking it away: `run` still opens the menu bar so nobody's alias breaks, but the verb
/// a person should type is `app`.
///
/// The refusal is the reason the new verb is worth having. The GUI started from
/// `.build/debug/Worklens` is not Worklens.app: it has no `Info.plist`, so no `LSUIElement`
/// (a Dock icon appears) and no `NSAppleEventsUsageDescription` (the browser-URL probe dies on
/// first use), and it carries a different signature, so every Screen Recording and Accessibility
/// grant made for the real app does nothing for it. That is a long afternoon of confusion, and
/// `make run` is one line.
struct AppCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Launch the Worklens menu-bar app (only from an installed Worklens.app).",
        discussion: "The app captures, describes and builds the timeline; Claude reads the "
            + "record through the MCP tools that `worklens mcp install` connects."
    )

    /// Non-nil when this binary must not put a menu bar on the screen.
    static var refusal: CLIFailure? {
        guard !BundleLayout.isBundled else { return nil }
        return .permission(
            "this is the development binary, not Worklens.app: launching the menu bar from it "
                + "gives you a Dock icon, no automation permission and none of the screen-recording "
                + "grants the real app has. Run `make run` (or open the installed Worklens.app) "
                + "instead."
        )
    }

    func run() throws {
        // `main.swift` intercepts a bare `worklens app` before ArgumentParser is involved: an
        // NSApplication has to come up from the top level of the process rather than from inside
        // an `AsyncParsableCommand.run()`, which is the trap the existing no-argument branch was
        // already avoiding. Reaching here means the interception did not match.
        throw AppCommand.refusal ?? .runtime("`worklens app` takes no arguments, just `worklens app`.")
    }
}
