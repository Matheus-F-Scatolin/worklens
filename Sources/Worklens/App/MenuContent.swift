import AppKit
import SwiftUI
import WorklensCore

/// The menu-bar menu (#231): what a menu-bar app's menu is on macOS — a status line, the few
/// actions you take from the menu bar, and the way into the windows.
///
/// **Mechanism.** `MenuBarExtra` in `.menu` style, so AppKit draws a real `NSMenu`: keyboard
/// navigable, VoiceOver-native, and dismissed by the same click every other menu is. #159's
/// popover was a window, which needed an AppKit hack to dismiss itself at all; a menu closes on
/// its own and that hack left with it.
///
/// **Scene actions.** `openSettings` and `openWindow` are *view* environment actions, and the
/// view that hands `AppModel` its copies is the menu-bar item's own label (`MenuBarLabel` in
/// `WorklensApp`), which SwiftUI evaluates at launch. This body is evaluated only when the menu
/// is opened, so it deliberately does not install them: the welcome window opens from
/// `AppModel.start()`, long before anyone opens a menu.
///
/// **No dashboard.** Twelve top-level rows at the most, one line of status, one tally, and at
/// most one row asking to be fixed. Everything the popover drew and this does not — the card,
/// the files rows, the banners — lives in the reader or in Settings; the pull request that
/// landed this lists where each one went.
///
/// Every string and every enabled flag is already computed in `MenuModel` or `TodaySnapshot`.
/// This file draws them and calls into `AppModel`; it does no arithmetic and formats no dates.
struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let menu = model.menu
        // Today's numbers, asked for when the menu opens and not on the 30 s loop.
        let _ = model.menuWillOpen()

        Group {
            statusRow(menu)
            tallyRow(menu)
            attentionRow(menu)
        }
        // The separator hangs off the rows, not the other way round: `captureRows` draws nothing
        // while Screen Recording is missing, and a Divider on its own is two separators in a row.
        if !menu.isDegraded, menu.permissionFixLine == nil {
            Divider()
            captureRows(menu)
        }
        Divider()
        Button(String(localized: "Open Worklens", comment: "Menu row")) { model.openReader() }
            .keyboardShortcut("o")
        Divider()
        deleteMenu()
        Divider()
        Group {
            Button(String(localized: "Settings…", comment: "Menu row")) { model.openSettings() }
                .keyboardShortcut(",")
            helpMenu()
            Button(String(localized: "Quit Worklens", comment: "Menu row")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    // MARK: The three lines at the top

    /// What Worklens is doing, in the words `MenuModel.statusRow` chose. A plain `Text` is a
    /// disabled row, which is what a status line should be — except before setup is finished,
    /// where the line is the offer to finish it and opens the welcome window (#131).
    @ViewBuilder
    private func statusRow(_ menu: MenuModel) -> some View {
        if let setup = menu.setupRow {
            Button(setup.text) { model.openSetup() }
        } else if let firstRun = menu.firstRunRow {
            Button(firstRun.text) { model.openSetup() }
        } else {
            Text(menu.statusLine)
        }
    }

    /// One tally line, or none: today's numbers, left out entirely before anything has been
    /// tracked. A degraded menu has none — the sentence that says what went wrong is the
    /// attention row below, so that the remedies hang off the words that named the fault.
    @ViewBuilder
    private func tallyRow(_ menu: MenuModel) -> some View {
        if let tally = model.menuTallyLine {
            Text(tally)
        }
    }

    /// At most one row that asks to be fixed, and only while something needs fixing.
    ///
    /// A configuration or a storage fault is a submenu rather than a row, because neither has a
    /// single answer: the three remedies are the three `ConfigBanner` offers in Settings, and
    /// choosing one of them here would be choosing for the user at the moment they are least
    /// able to say which they want. The submenu's title is the sentence that says what went
    /// wrong — `MenuModel` puts it in the counts slot — so the fault is still one line of text
    /// and the remedies hang off it. Everything else is one row whose click performs the fix.
    @ViewBuilder
    private func attentionRow(_ menu: MenuModel) -> some View {
        switch menu.degraded {
        case .configuration:
            Menu(menu.countsLine) {
                Button(String(localized: "Reload configuration", comment: "Menu row")) {
                    model.reloadConfig()
                }
                Button(String(localized: "Use defaults and start", comment: "Menu row")) {
                    model.startOnDefaults()
                }
                Button(String(localized: "Open .env…", comment: "Menu row")) { model.openEnvFile() }
            }
        case .storage:
            Menu(menu.countsLine) {
                Button(String(localized: "Choose a data folder in Settings…", comment: "Menu row")) {
                    model.openSettings(.usage)
                }
                Button(String(localized: "Open .env…", comment: "Menu row")) { model.openEnvFile() }
                Button(String(localized: "Try again", comment: "Menu row")) { model.reloadConfig() }
            }
        case .none:
            // #117: the one grant that stops capture, and the click that asks for it.
            if let fix = menu.permissionFixLine {
                Button(fix) { model.requestScreenRecording() }
            } else if let problem = menu.problem, let line = menu.problemLine {
                // The notice's own remedy where it has one; Settings → General, whose status line
                // lists every open notice (#286), where it does not.
                Button(line) {
                    if let action = problem.action {
                        model.perform(action)
                    } else {
                        model.openSettings(SettingsTarget(.status))
                    }
                }
            } else if let attention = menu.integrationAttentionLine {
                // #141: a source whose token was refused or whose grant was revoked.
                Button(attention) { model.openSettings(SettingsTarget(.sources)) }
            } else if let health = menu.describeHealthLine {
                // #299: a 503 or a schema stall puts "!" on the icon; this is the reason, now
                // that the hover text that used to carry it is gone.
                Button(health) {
                    if let action = menu.describeFixAction {
                        model.perform(action)
                    } else {
                        model.openSettings(SettingsTarget(.status))
                    }
                }
            }
        }
    }

    // MARK: Capture

    /// Pause (or Resume, or Start capturing) and Capture now — #136's semantics, unchanged.
    ///
    /// Left out entirely while Screen Recording is missing — the caller's condition now, so that
    /// the separator in front of these rows goes with them: there is nothing to pause and nothing
    /// to capture, and the row above already offers the one thing that changes that.
    @ViewBuilder
    private func captureRows(_ menu: MenuModel) -> some View {
        Group {
            if menu.canPause {
                Menu(String(localized: "Pause", comment: "Menu")) {
                    ForEach(PauseChoice.allCases, id: \.self) { choice in
                        Button(choice.label) { model.pause(choice) }
                            // While capturing, ⌘P is "pause until I resume" — the mirror of the
                            // ⌘P that resumes, so neither state has to hunt for it.
                            .keyboardShortcut(choice == .untilResumed ? KeyboardShortcut("p") : nil)
                    }
                }
            } else if menu.canResume {
                Button(String(localized: "Resume", comment: "Menu row")) { model.startOrResume() }
                    .keyboardShortcut("p")
            } else {
                Button(String(localized: "Start capturing", comment: "Menu row")) {
                    model.startOrResume()
                }
                .keyboardShortcut("p")
            }
            Button(String(localized: "Capture now", comment: "Menu row")) { model.captureNow() }
                .keyboardShortcut("n")
                .disabled(!menu.canCaptureNow)
        }
    }

    // MARK: Delete

    /// Away from the capture rows, as in the old menu: these are what you reach for after
    /// something private happened on screen, and they must not be one slip away from "Pause".
    /// "Delete" and not "erase" — one verb per action (`docs/copy.md`).
    private func deleteMenu() -> some View {
        Menu(String(localized: "Delete", comment: "Menu")) {
            Button(String(localized: "Last 10 minutes…", comment: "Menu row")) {
                model.eraseRecent(minutes: 10)
            }
            Button(String(localized: "Last hour…", comment: "Menu row")) {
                model.eraseRecent(minutes: 60)
            }
        }
    }

    // MARK: Help

    /// Everything a person reaches for when Worklens is the problem (#153). Troubleshooting is
    /// load-bearing: `AppModel.openTroubleshooting(_:)` — the route that lands on one symptom —
    /// is reachable from here and nowhere else in the app.
    private func helpMenu() -> some View {
        Menu(String(localized: "Help", comment: "Menu")) {
            Button(String(localized: "Getting started…", comment: "Menu row")) {
                model.openHelp(.firstDay)
            }
            Button(String(localized: "Privacy…", comment: "Menu row")) { model.openPrivacyDoc() }
            Button(String(localized: "Troubleshooting…", comment: "Menu row")) {
                model.openTroubleshooting()
            }
            Button(String(localized: "Open log folder", comment: "Menu row")) {
                model.openLogFolder()
            }
        }
    }
}
