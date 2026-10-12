import AppKit
import SwiftUI
import UserNotifications
import WorklensCore

struct WorklensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(
                model: model,
                icon: model.menu.icon,
                busy: model.menu.isBusy,
                name: model.menu.iconLabel,
                tally: model.menu.spokenTally
            )
        }
        // #231: a real `NSMenu` again, after #159's popover — keyboard-navigable, VoiceOver-
        // native, and dismissed like every other menu on macOS. Still a `MenuBarExtra` and not a
        // hand-made `NSStatusItem`: the three `Window` scenes below are reachable only through the
        // `openWindow` action a view in this scene graph hands to `AppModel`, and the label view
        // below is that view.
        .menuBarExtraStyle(.menu)

        // #131: the first five minutes, in order, before anything is captured. Opened from
        // `AppModel.start()` when `app_state` has no `onboarded_at`, and re-openable from the
        // menu and from Settings → General. Same scene idiom as the reader below it.
        // Fixed rather than resizable since #232: five pages of one column (#352), sized in
        // `Theme.SetupWindow`, and nothing on any of them wants a wider window.
        Window(SetupCopy.windowTitle, id: AppModel.setupWindowID) {
            SetupWindowView(model: model)
        }
        .windowResizability(.contentSize)

        // #134: where your own days are read. #95 removed the *chat* window, on the argument
        // that Claude Desktop reads the same data better through the MCP server; this makes no
        // model call of its own, and it replaces `NSWorkspace.open` on a `.md` file rather than
        // a chat client. `AppModel.openWindow(id:)` fronts it — a `.menu` MenuBarExtra is never
        // the frontmost app, so the model-side route activates first.
        //
        // #286: Settings is a page of this window too — the gear at the foot of the rail — so
        // there is no `Settings` scene any more, and no second window to sit above this one
        // (#279).
        Window(ReaderCopy.windowTitle, id: AppModel.readerWindowID) {
            ReaderView(model: model)
        }
        .windowResizability(.contentMinSize)
        // No `.commands` for ⌘← / ⌘→: they live inside `ReaderView`, where the window itself is
        // the responder, which works whether or not `DockPresence` has put a menu bar up yet.
        // The menu bar across the top, which exists only while a window is open (`DockPresence`).
        .commands { WorklensCommands(model: model) }

    }
}

/// What the top menu bar says while Worklens is a Dock app. SwiftUI's default Help menu would open
/// a Help book this bundle does not have; it goes where the menu-bar icon's own rows go instead.
private struct WorklensCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // #286: with no `Settings` scene SwiftUI draws no "Settings…" of its own, so ⌘, is
        // this row — the page in the reader window, from whichever window is in front.
        CommandGroup(replacing: .appSettings) {
            Button(String(localized: "Settings…", comment: "Menu row")) { model.openSettings() }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .help) {
            Button(String(localized: "Getting started…", comment: "Menu row")) {
                model.openHelp(.firstDay)
            }
            Button(String(localized: "Privacy…", comment: "Menu row")) { model.openPrivacyDoc() }
            Button(String(localized: "Troubleshooting…", comment: "Menu row")) {
                model.openTroubleshooting()
            }
            Divider()
            Button(String(localized: "Open log folder", comment: "Menu row")) {
                model.openLogFolder()
            }
        }
    }
}

/// The menu-bar icon itself: the drawn mark, the SF Symbol if drawing ever fails, and — either
/// way — a name and a value for VoiceOver, because an icon whose whole job is to say what
/// Worklens is doing should say it to VoiceOver too.
///
/// #132 split those in two. The label is `MenuModel.iconLabel`, a sentence written for speech
/// ("Worklens, capturing every 60 seconds") rather than the menu row's abbreviated `every 60 s`;
/// the value is today's tally, which is the next thing anyone asks and the only other fact the
/// item can offer without being opened.
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    let icon: MenuIcon
    /// #252: a treatment over `icon`, not one of its values — a paused app running a sync is
    /// still paused, and the menu bar has to be able to say both.
    let busy: Bool
    let name: String
    /// #252: today's numbers as a sentence. `countsLine` is an interpunct row written for a
    /// glance, which VoiceOver reads as a run of digits.
    let tally: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // #131: this body is evaluated at launch — the menu-bar item has to draw — while
        // `MenuContent`'s only runs when somebody opens the menu. The welcome window is opened
        // from `AppModel.start()`, so without a copy of the scene actions here the first launch
        // of a new install would ask for a window nothing could open. #231 leaves this as the
        // only installer: a `.menu` MenuBarExtra hands its content view to AppKit, and the one
        // view that is certainly in the scene graph is this label. `installSceneActions` stores
        // into plain properties and publishes nothing.
        let _ = model.installSceneActions(openWindow: { openWindow(id: $0) })
        Group {
            if let glyph = MenuBarGlyph.image(for: icon, busy: busy) {
                Image(nsImage: glyph)
            } else {
                Image(systemName: icon.rawValue)
            }
        }
        .accessibilityLabel(name)
        .accessibilityValue(tally)
    }
}

/// SwiftUI gives no scene-level "the app is quitting" hook, and `MenuBarExtra` alone leaves the
/// app running with no windows — both are what this delegate is for.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two Worklenses against one data directory means two capture timers, two describe
        // queues and a budget that only sees half the spend. The one already running wins, and
        // this one leaves quietly — a menu-bar app being "opened" while it sits in the menu bar
        // is a normal thing for a person to do, not an error worth a dialog.
        if SingleInstance.anotherAppIsRunning() {
            NSApp.terminate(nil)
            return
        }
        Log.ui.info("Worklens \(WorklensVersion.short) starting (menu bar)")
        DevAppIcon.applyWhenUnbundled()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            // #149: before anything can post one. A banner whose category was never
            // registered has no button and no click that goes anywhere.
            Notifier.registerCategories()
        }
        // #147: `worklens settings` posts the first of these, and a second copy — `make run`
        // against an installed app, say — the second on its way out (#279). Registered after the
        // check above, so the copy that is about to terminate never hears its own request.
        revealObservers = [
            SettingsReveal.observe { target in
                MainActor.assumeIsolated { AppModel.shared.openSettings(target) }
            },
            SettingsReveal.observeHome {
                MainActor.assumeIsolated { AppModel.shared.frontHomeWindow() }
            },
        ]
        MainActor.assumeIsolated {
            DockPresence.shared.start()
            AppModel.shared.start()
        }
    }

    /// The observers behind #147's second-launch handshake, held for the life of the app.
    private var revealObservers: [NSObjectProtocol] = []

    deinit {
        for observer in revealObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    /// Re-opening the *same* bundle — from Spotlight, from Finder, from the Dock tile — never
    /// starts a second process: LaunchServices activates this one
    /// and sends it this message instead. Without the handler it is a no-op, which is how an
    /// `LSUIElement` app whose status item is hidden behind the notch becomes unreachable (#147).
    ///
    /// `hasVisibleWindows` is ignored on purpose: a reader window buried three apps back is not
    /// an answer to "I re-opened the app because I could not find it".
    ///
    /// #252: the home window, not Settings. Since #233 the reader *is* the app as far as a
    /// person is concerned, and answering a Dock click with a preferences pane is the answer to
    /// a question nobody asked. It is the same thing the ⌥⇧W shortcut does.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.frontHomeWindow() }
        return true
    }

    // No SIGTERM handler here. The obvious one — `signal(SIGTERM, SIG_IGN)` plus a
    // `DispatchSource` signal source that calls `NSApp.terminate`, which is what
    // the CLI scheduler once used — turns SIGTERM into a no-op in *this* app: the source
    // never fires, and because SIG_IGN has already disabled the default action, the app
    // cannot be stopped by `kill` at all. The same code fires as expected in a bare
    // NSApplication binary, bundled and launched through LaunchServices, so the cause is
    // something about this app that is still unexplained; until it is, leaving the default
    // disposition alone is what keeps `scripts/update.sh` able to stop the app.

    private var isTerminating = false

    /// Shutdown is asynchronous (the describe worker may be mid-call, the timeline mid-rebuild),
    /// so quitting goes through `.terminateLater` rather than blocking the main thread in
    /// `applicationWillTerminate` — which would deadlock against the main-actor work it waits on.
    /// #18 adds the SQLite checkpoint and the log flush to `AppModel.shutdown()`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        Task { @MainActor in
            await AppModel.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        // Never hold the quit hostage: whatever has not finished in five seconds is abandoned.
        DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.shutdownGrace) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    static let shutdownGrace: TimeInterval = 5

    /// A banner while Worklens is frontmost would otherwise be swallowed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// What a click does. #149: until then clicking a banner did nothing at all — the body had
    /// to tell people to go and find the menu themselves.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        switch content.categoryIdentifier {
        case Notifier.permissionCategory:
            ScreenCaptureService.openScreenRecordingSettings()
        case Notifier.databaseCategory:
            if let path = content.userInfo[Notifier.Key.path] as? String {
                // NSWorkspace is AppKit, and this delegate runs on whatever thread the
                // notification centre calls it on, so it hops to the main actor.
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        default:
            break
        }
    }
}
