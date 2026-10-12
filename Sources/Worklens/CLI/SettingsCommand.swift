import AppKit
import ArgumentParser
import WorklensCore

/// `worklens settings [--tab <section>]` — bring the running app's window to the front on Settings.
///
/// The developer's door back in when the menu-bar icon cannot be found (#147). It never starts a
/// second Worklens: a second one would capture on its own timer and split the budget in two, so
/// this only asks the one that is already running, over `SettingsReveal`, and exits. With nothing
/// running it says so rather than launching anything.
struct SettingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Bring the running Worklens to the front on Settings."
    )

    @Option(name: .long, help: "Which section to open on: \(SettingsReveal.tabNames.joined(separator: ", ")).")
    var tab: String?

    func run() throws {
        // #286: the section's own name goes over the wire, never the old pane's — an old name is
        // folded into its section here, so the running app only ever hears one of the seven.
        var section: SettingsSection?
        if let tab {
            guard let named = SettingsReveal.target(named: tab) else {
                throw ValidationError(
                    "unknown tab \"\(tab)\", one of: \(SettingsReveal.tabNames.joined(separator: ", "))"
                )
            }
            section = named.section
        }

        // Matching on the bundle identifier alone would miss a checkout run — `swift run Worklens
        // run` has no bundle identifier, so it is invisible to `runningApplications(withBundle…)`
        // even though it registered the same observer. Its executable name is what is left.
        let mine = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != mine
                && SettingsReveal.isWorklens(
                    bundleIdentifier: $0.bundleIdentifier,
                    executableName: $0.executableURL?.lastPathComponent
                )
        }
        guard let app = running.first else {
            FileHandle.standardError.write(Data(
                ("Worklens is not running. Open Worklens.app: from Spotlight, or "
                    + "/Applications, and it will show this window itself.\n").utf8
            ))
            throw ExitCode.failure
        }

        // Activating from here is what puts the app in front; the window itself is opened by the
        // app's own observer, which activates again on the way (a `.menu` MenuBarExtra is never
        // frontmost, so one of the two would not be enough on its own).
        app.activate(options: [])
        SettingsReveal.post(tab: section)
        // The stable `rawValue`, not the localized `title`: this is CLI output, which stays
        // English, and the installed `worklens` is a symlink into the app bundle — so
        // `Bundle.main` there *is* the bundle with the `.lproj` catalogs in it and a title would
        // come back translated. `rawValue` is also the spelling `--tab` takes.
        print("Asked Worklens (pid \(app.processIdentifier)) to show Settings\(section.map { " → \($0.rawValue)" } ?? "").")
    }
}
