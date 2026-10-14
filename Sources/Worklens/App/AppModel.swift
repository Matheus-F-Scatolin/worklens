import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications
import WorklensCore

/// The one object that owns the running app: config, database, and every service that touches
/// them. The menu and the Settings window are views over it and hold nothing of their own.
///
/// Everything here is main-actor because the menu reads it on every open; the expensive work
/// lives in the actors it drives (`DescribeWorker`, `TimelineWriter`).
@MainActor
final class AppModel: ObservableObject {
    /// One per process. The `App` struct and the `NSApplicationDelegate` both need it, and
    /// SwiftUI gives no way to hand one to the other.
    static let shared = AppModel()

    // MARK: Published state

    /// Everything the menu draws from, rendered. The app is the one place a real person reads
    /// these strings, so this is where the user's own locale is handed to `MenuModel` (#157).
    @Published private(set) var menu = MenuModel(state: MenuState(locale: .autoupdatingCurrent))
    @Published private(set) var screenRecording: PermissionState = .unknown
    /// #53: whether this build may read the focused window's accessibility tree. Never asked for
    /// on launch — only checked — so the app cannot put a TCC dialog in front of somebody who
    /// only wanted a menu bar icon.
    @Published private(set) var accessibilityTrusted = AccessibilityPermission.isTrusted
    @Published private(set) var notifications: UNAuthorizationStatus = .notDetermined
    /// Last 30 days of spend, for Settings → Models & cost. Refreshed when Settings opens.
    @Published private(set) var spendHistory: [DailySpend] = []
    /// What `DATA_DIR/screenshots` weighs right now, for Settings → Models & cost. Measured at
    /// launch and after every sweep, not on every render: it is a directory walk.
    @Published private(set) var screenshotBytes: Int64 = 0
    /// #137: today's one-day budget raise, or nil. Settings shows it; nothing else needs it,
    /// because every budget decision is made against `CostTracker.budgetUSD`.
    @Published private(set) var budgetOverrideUSD: Double?
    /// #125: when a frame was last summarized. "Running normally" means little on its own;
    /// Settings → Models & cost puts this next to it.
    @Published private(set) var lastDescribedAt: Date?
    /// #18's Settings → General toggle, read from `SMAppService` rather than remembered.
    @Published private(set) var launchAtLogin: LaunchAtLogin.State = .disabled
    /// The pause hotkey in force, or nil when it could not be registered (another app owns it).
    @Published private(set) var pauseHotkey: HotkeySpec?
    /// #252: the hotkey that opens and fronts the home window, on the same terms. Settable
    /// package-wide rather than `private(set)` only because the code that registers it lives in
    /// `AppModel+Menu.swift`, and Swift scopes `private(set)` to the file.
    @Published var openHotkey: HotkeySpec?
    /// #252: true when the combination last asked for in this row is the one Worklens's *other*
    /// shortcut already holds. The window server answers that with the same error another app's
    /// claim produces, so it is checked before registering and said in its own words.
    @Published private(set) var pauseHotkeyClashesWithOpen = false
    @Published var openHotkeyClashesWithPause = false
    /// Mirrors `MenuState`, so Settings can read individual fields without re-deriving them.
    @Published private(set) var state = MenuState(locale: .autoupdatingCurrent)
    /// What the auto-updater has to say — "A new version is available, but this copy can't
    /// install it." — or nil when the running build *is* `origin/main`. Only ever a line in the
    /// version row; nothing about it is urgent.
    @Published var updateAvailableLine: String?
    /// Whether the last **Check now** found a new version this copy can install, which is when
    /// Settings shows **Update and restart…**.
    @Published var updateOffered = false
    /// What Settings → General → Updates' **Check now** last answered (#153), or nil until it is
    /// pressed. Separate from `updateAvailableLine`, which is the poller's line: one is a fact
    /// about this install, the other is the reply to a question somebody just asked.
    @Published var updateCheckLine: String?
    /// A check is in flight. `git ls-remote` over a slow network takes seconds, and a button that
    /// looks inert is a button people press again.
    @Published var checkingForUpdates = false
    /// #131: which page the welcome window is showing. Held here rather than in the view so
    /// that re-opening from Settings always starts at page 1, and so a configuration reload —
    /// which rebuilds the whole stack — cannot lose the place somebody was at.
    @Published var setupPage: SetupPage = .appearance
    /// #286: the Settings section the reader window is showing in place of a reading page, or nil
    /// while it shows one. Settings is not a `ReaderPlace`: the rail's two places stay the
    /// reading places, `readerPlace` keeps the one you came from, and setting this back to nil is
    /// all Esc has to do.
    @Published var settingsSection: SettingsSection?
    /// #286: the row a route asked Settings to light up — "Review" on the status line, the old
    /// Permissions pane, a notice's "Add a Gemini key". The page scrolls to it, flashes it once and
    /// clears this.
    @Published var settingsHighlight: SettingsAnchor?
    /// #286: the "Saved" toast at the foot of the Settings page. A counter in `id`, so saving the
    /// same row twice in a row still shows the toast twice.
    @Published var settingsToast: SettingsToast?
    /// #286: what the loader said about a value a Settings row tried to save, by key, until that
    /// row saves one it accepts. Kept here rather than in each row, so a row redrawn by a reload
    /// still shows why its last value was refused.
    @Published var settingsFailures: [String: String] = [:]
    /// #286: when today's first screenshot was taken, for General's "capturing since". Read when
    /// General appears, never on a render.
    @Published var settingsFirstCapture: Date?
    /// #147: whether the Dock icon stays when no window is open. Every window already brings one
    /// with it (`DockPresence`); this keeps it after the last one closes, for someone whose
    /// menu-bar item is not reachable, as a permanent second door. Off by default, and applied at
    /// runtime, so neither turning it on nor turning it off needs a relaunch.
    @Published private(set) var showInDock = false
    /// Settings → General → "Appearance": follow the system, or hold light or dark. Applied to
    /// `NSApp.appearance`, so every window and the reader's dynamic colours switch at once.
    @Published private(set) var appearance: AppearanceChoice = .system

    // MARK: Services

    private(set) var config: Config
    /// Which layer supplied each key at the last load. Published so a Settings control can grey
    /// itself out when something above the settings file wins its key (#108).
    @Published private(set) var configProvenance = ConfigProvenance()
    /// The app-owned settings layer (`~/Library/Application Support/Worklens/settings.json`).
    let settings = SettingsStore()
    /// The app-owned half of the three blocklists (#128), beside that file. Published as the
    /// overlay it holds, so Settings → Privacy can mark which rows you added.
    let blocklists = BlocklistStore()
    @Published private(set) var blocklistOverlay = BlocklistOverlay()
    private(set) var db: Database?
    private(set) var taxonomy: TaxonomyStore?
    private(set) var capture: ScreenCaptureService?
    private(set) var scheduler: CaptureScheduler?
    /// #46: exact foreground intervals from `NSWorkspace`, running exactly when capture runs.
    private(set) var sessionRecorder: ForegroundSessionRecorder?
    private(set) var describe: DescribeWorker?
    private(set) var timeline: TimelineWriter?

    /// #90: the canonical project list, for the Projects settings tab. Nil until the stack is up.
    var projectCatalog: ProjectCatalog? {
        guard let db, let taxonomy else { return nil }
        return ProjectCatalog(db: db, taxonomy: taxonomy)
    }
    /// #19: pulls Granola and Google Calendar on a timer, and tells `MeetingDetector`
    /// which scheduled call is running so capture drops to `MEETING_CAPTURE_INTERVAL_SECONDS`.
    private(set) var contextSync: ContextSyncScheduler?
    /// #139: whether the banner for the current expiry has already been posted. One per incident:
    /// cleared the moment a sync succeeds again.
    private var googleReconnectNotified = false
    /// The detector `contextSync` feeds. Held rather than left inside `buildServices` so a
    /// context-only reload (#135) can hand the rebuilt scheduler the same instance the running
    /// capture scheduler is already consulting.
    private(set) var meetingDetector: MeetingDetector?
    /// Bumped once per applied configuration. A Settings pane that keeps its own derived state —
    /// Integrations reads the scheduler's statuses — observes this to know it has gone stale,
    /// which is what a `Config` snapshot taken in `init` could never tell it (#135).
    @Published private(set) var configGeneration = 0
    /// #17: the ledger and the daily budget. Every service that can spend money holds this one.
    private(set) var cost: CostTracker?
    /// #16: "delete the last ten minutes" and the date-range purge.
    private(set) var eraser: DataEraser?
    /// #18: keeps `DATA_DIR/screenshots` under `SCREENSHOT_DISK_BUDGET_GB`.
    private(set) var disk: DiskBudget?
    /// #144: lets the history age out at `RETENTION_DAYS`. Nil is not "off" — off is the
    /// default `RETENTION_DAYS=0`, which this asks about and then does nothing.
    private(set) var retention: Retention?

    private var cancellables: Set<AnyCancellable> = []
    /// The reload in flight, if any. Every reload chains onto it (#135): applying one suspends
    /// twice — stopping the old services and starting the new — and two of them interleaving on
    /// the main actor leaves one task's freshly built scheduler assigned to a field the other
    /// then nils, with nothing left holding it and nothing able to stop it. One Save in the
    /// integrations sheet writes two keys, so that was two reloads in a single turn.
    private var reloadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var readerTickTask: Task<Void, Never>?
    private var housekeepingTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Nil when auto-update is off, or when this app has no checkout to update from.
    private var autoUpdater: AutoUpdater?
    /// `DATA_DIR/.lock`, held for the life of the app so a second Worklens on the same data
    /// directory cannot capture the same screen twice.
    private var instanceLock: InstanceLock?
    /// #122: `DATA_DIR` is somewhere capture must not write. Held rather than re-derived so the
    /// menu's own "Start capturing" and "Capture now" cannot walk around the refusal.
    private var dataDirBlocked = false
    private var started = false
    /// Set while Screen Recording is gone, so the "permission lost" banner is posted once per
    /// incident rather than once per retry, and "capturing again" only follows a real loss.
    ///
    /// #117 made the incident outlive the process: it is restored from
    /// `permission_incident_started_at` at launch, so relaunching into a still-missing grant
    /// re-raises the menu line without posting the same notification again. Relaunching is
    /// exactly what the first grant asks of the user, and being told off for it twice is not a
    /// way to treat somebody who is doing what the app suggested.
    private var permissionIncident = false
    /// #117: whether Screen Recording has ever been granted to this build, from
    /// `screen_recording_granted_at`. `CGPreflightScreenCaptureAccess()` answers false both for
    /// a Mac that has never been asked and for one that revoked the grant, and those two need
    /// opposite sentences — see `ScreenRecordingCopy`.
    private(set) var screenRecordingEverGranted = false
    /// When the scheduler last reported anything but idle/locked/asleep. The weekly `VACUUM`
    /// waits for ten minutes of this being in the past.
    private var busySince: Date? = Date()

    /// How often the counters are re-read when nothing else has happened.
    static let refreshInterval: TimeInterval = 30
    /// How often an open reader is brought up to date.
    static let readerTickInterval: TimeInterval = 60
    /// How often the disk budget, the day rollover and the `VACUUM` question are revisited.
    static let housekeepingInterval: TimeInterval = 15 * 60
    /// How long the app must have been idle before a `VACUUM` is allowed to take the write lock.
    static let vacuumIdleRequirement: TimeInterval = 10 * 60
    /// At most one `VACUUM` a week.
    static let vacuumInterval: TimeInterval = 7 * 24 * 3600
    /// `app_state` key holding the last `VACUUM`.
    static let lastVacuumKey = "last_vacuum_at"
    /// `app_state` key behind Settings → General → "Start capturing on launch".
    static let startOnLaunchKey = "start_capturing_on_launch"
    /// `app_state` key holding the Settings section the user last looked at (#112). The spelling
    /// predates #286, so a stored old pane name is folded into its section on the way back in.
    /// `app_state` key behind Settings → General → "Show Worklens in the Dock" (#147). Absent —
    /// every install until someone turns it on — means no Dock icon, which is what
    /// `LSUIElement=true` in `Resources/Info.plist` gives on its own.
    static let dockIconKey = "show_dock_icon"
    /// `app_state` key behind Settings → General → "Appearance". Absent means `system`.
    static let appearanceKey = "appearance"
    /// `app_state` key stamped the first time Screen Recording is seen granted (#117). Its
    /// presence, never its value, is what tells "not on yet" from "lost".
    static let screenRecordingGrantedKey = "screen_recording_granted_at"
    /// `app_state` key holding when the current Screen Recording outage began (#117). Written
    /// once per incident, deleted when the grant comes back, and read at launch so a relaunch
    /// does not re-notify.
    static let permissionIncidentKey = "permission_incident_started_at"
    /// `app_state` keys behind Settings → Permissions → "Don't remind me": each silences one
    /// optional-permission line in the menu and nothing else (#117).
    static let skipAccessibilityAdvisoryKey = "skip_accessibility_advisory"
    static let skipBrowserAdvisoryKey = "skip_browser_advisory"
    /// `app_state` key stamped when the welcome window is finished (#131) — or written silently
    /// under an install that predates the window. Its presence, never its value, is what decides
    /// whether the window is shown at all.
    static let onboardedKey = "onboarded_at"

    // MARK: Lifecycle

    init() {
        // A broken `.env` must not stop the menu from appearing: the app comes up degraded, says
        // why, and offers to open the file.
        do {
            let loaded = try Config.loadWithProvenance()
            config = loaded.config
            configProvenance = loaded.provenance
            blocklistOverlay = blocklists.load()
            Log.configure(config)
            applyConfigDiagnostics(loaded.provenance)
        } catch {
            config = Config.defaults()
            // The values did not survive, but which files were read is still knowable — and it is
            // what the user needs to see now, both in the menu and when recording `.launch-env`.
            configProvenance = Config.provenance()
            Log.configure(config)
            // #126: the same multi-error information the reload path raises, at startup too.
            // Settings renders `Config.defaults()` while this stands, so the banner has to say
            // which values are wrong, in which file, and that the tabs are showing defaults.
            applyConfigError(error)
            Log.ui.error("configuration error: \(error)")
        }
        state.budgetUSD = config.dailyBudgetUSD
        state.captureIntervalSeconds = config.captureIntervalSeconds
        state.meetingIntervalSeconds = config.meetingCaptureIntervalSeconds
        state.batteryMode = config.captureOnBattery
        render()
        if state.configError == nil { buildServices() }
    }

    /// Starts the scheduler, the describe worker and the two timers. Called once, from the app
    /// delegate, so constructing an `AppModel` never has side effects on the disk or the screen.
    func start() {
        guard !started else { return }
        started = true

        restoreDockIcon()
        restoreAppearance()
        announceUpdateReturn()
        restorePermissionState()
        checkPreviousRun()
        writeStarterEnvIfNeeded()
        recordLaunchEnvironment()
        // #131: `Notifier.requestAuthorization()` used to be the first statement of this method,
        // which made an unexplained notifications dialog the very first thing a new install did
        // — before anything had said what Worklens records. It is page 4 of the welcome window
        // now, behind a button, and Settings → Permissions has the same button for an install
        // that skipped it.
        recheckPermissions()
        registerPauseHotkey()
        registerOpenHotkey()
        launchAtLogin = LaunchAtLogin.state()
        observeWake()

        // #122. A folder a file provider syncs cannot hold a SQLite database safely, and the
        // lock below is a kernel lock this Mac cannot enforce on another one. Same shape as the
        // instance lock: not fatal — reading and the CLI's queries are all still fine —
        // but capturing into it is exactly what must not happen.
        checkDataDirLocation()
        recordMachineName()

        // The lock keeps two copies of the app from both capturing into one data directory.
        // Failing to get it is not fatal — reading the data is still fine — but capturing is
        // exactly what must not happen twice.
        instanceLock = InstanceLock.acquire(dataDir: config.dataDir)
        // #131: decided before the capture branch below, because on a fresh install the answer
        // is "nothing starts until the user has been told what this records and has pressed
        // Start capturing".
        startSetupIfNeeded()
        // #349: whether the reader opens on the invented sample week, decided before capture.
        prepareSampleWeek()
        // #248 fills this in; the line is here so that issue needs no edit of its own in this
        // file (#246).
        startMCPHealthWatch()
        if dataDirBlocked {
            Log.ui.info("not starting capture: DATA_DIR is not on this Mac's own disk")
        } else if instanceLock == nil {
            note(error: "Another Worklens is capturing into \(config.dataDir.lastPathComponent) "
                + "(it holds .lock). Not starting capture.")
        } else if setupPending {
            // #131: the welcome window is on screen. Nothing is captured until its last page is
            // pressed, which is the whole point of showing it before anything happens.
            Log.ui.info("not starting capture: the welcome window has not been finished yet")
        } else if shouldStartCapturing() {
            // A pause set before the last quit — or before the updater's own restart — comes back
            // with it (#113). The loop still starts, or a timed pause could never expire; the
            // recorder is left to `syncSchedulerState()`, which mirrors the scheduler's state onto
            // it and so keeps "paused records nothing" true through the restore.
            scheduler?.startRestoringPause()
            syncSchedulerState()
            if case .paused? = scheduler?.state {
                Log.ui.info("capture is still paused from before the last quit")
            } else {
                sessionRecorder?.start()
            }
        } else {
            Log.ui.info("not starting capture: \"start capturing on launch\" is off")
        }
        Task { await describe?.start() }
        Task { await timeline?.rebuildRecentDays() }
        if let contextSync { Task { await contextSync.start() } }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppModel.refreshInterval))
                guard let self else { return }
                await self.refreshCounters()
                self.recheckPermissions()
                self.remindIfStillPaused()
            }
        }
        readerTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppModel.readerTickInterval))
                guard let self else { return }
                await self.runReaderTick()
            }
        }
        housekeepingTask = Task { [weak self] in
            // The first pass runs at launch, as #18 asks: the disk budget and the day rollover
            // are both things a Mac that was off overnight needs done before anything else.
            await self?.runHousekeeping()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppModel.housekeepingInterval))
                guard let self else { return }
                await self.runHousekeeping()
            }
        }
        Task { await refreshCounters() }
        startAutoUpdater()
    }

    /// Sets `dataDirBlocked` and raises the persistent row, or clears it when the folder is on
    /// this Mac's disk after all.
    ///
    /// `ALLOW_NONLOCAL_DATA_DIR=true` skips the check entirely — it is a safety catch, and
    /// someone who has read what it protects against may still decide to take the risk.
    private func checkDataDirLocation() {
        guard !config.allowNonLocalDataDir, let location = DataDirLocation.check(config.dataDir) else {
            dataDirBlocked = false
            return clear(.dataDirNotLocal)
        }
        dataDirBlocked = true
        raise(.dataDirNotLocal, message: location.menuMessage)
        // The whole explanation goes to the log, where there is room for it. The path is a
        // folder the user chose, not a captured window title, so it is safe at this level.
        Log.storage.warn(location.explanation)
    }

    /// What the two menu actions that start capturing ask before they do. Re-checks rather than
    /// reading the flag, so a `DATA_DIR` that moved since launch gets an answer that is true now.
    private func refusedForDataDir() -> Bool {
        checkDataDirLocation()
        return dataDirBlocked
    }

    /// Stamps this Mac onto the data directory, and says so when the folder already belonged to
    /// another one. Not a reason to stop capturing — the folder may simply have been copied here,
    /// or this Mac renamed — but it is the only thing that catches two Macs sharing one history
    /// through a sync the location check did not see.
    private func recordMachineName() {
        guard let db else { return }
        let match = MachineName.record(in: AppStateStore(db))
        if let message = match.message {
            raise(.dataDirAnotherMac, message: message)
        } else {
            clear(.dataDirAnotherMac)
        }
    }

    /// The poller that makes a commit on `main` reach this Mac without anybody clicking
    /// "Update and restart…". Off when `AUTO_UPDATE_ENABLED=false`, and impossible for a copy of
    /// the app that was dragged out of the checkout it was built from.
    private func startAutoUpdater() {
        guard config.autoUpdateEnabled, let repo = AppModel.repoRoot else { return }
        let updater = AutoUpdater(repo: repo, pollMinutes: config.autoUpdatePollMinutes, model: self)
        autoUpdater = updater
        updater.start()
    }

    /// Stops everything and flushes what is in flight, in the order that loses least: the
    /// scheduler first (so nothing new starts), then the in-flight describe call, then the
    /// timeline, then the write-ahead log, and the log file last — so the line saying Worklens
    /// stopped is itself on disk.
    ///
    /// Bounded by the 5 s watchdog in `AppDelegate`: whatever has not finished by then is
    /// abandoned, which is why the checkpoint comes before the slowest thing here rather than
    /// after it.
    func shutdown() async {
        autoUpdater?.stop()
        autoUpdater = nil
        refreshTask?.cancel()
        readerTickTask?.cancel()
        housekeepingTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        GlobalHotkey.shared.unregister()
        scheduler?.stop()
        sessionRecorder?.stop()
        await contextSync?.stop()
        await describe?.stop()
        await timeline?.flush()
        // Truncating the WAL is what keeps a `-wal` the size of a day's writes from outliving
        // the process, and what makes the next launch's `quick_check` fast.
        do {
            try db?.checkpoint()
        } catch {
            Log.storage.warn("WAL checkpoint at shutdown failed: \(error)")
        }
        // #156: last, and after the checkpoint, because the marker claims everything above
        // finished. Anything that ends the app before this line is what the next launch reports.
        markCleanExit()
        Log.ui.info("Worklens stopped")
        FileLog.shared.stop()
        instanceLock = nil
    }

    private func buildServices() {
        do {
            let db = try Database(dataDir: config.dataDir)
            // Owner-only modes on everything an older build or the umask left readable: a stat
            // per file, so off the main thread.
            let dataDir = config.dataDir
            Task.detached(priority: .utility) {
                let changed = FilePermissions.tightenTree(at: dataDir)
                if changed > 0 { Log.storage.info("made \(changed) data file(s) private to this account") }
            }
            let taxonomy = try TaxonomyStore(dataDir: config.dataDir)
            // #312: apps a later seed added, merged once, before anything resolves a frame.
            do {
                try AppLabelRepair(db: db, taxonomy: taxonomy).mergeIfDue()
            } catch let TaxonomyError.invalidTaxonomy(problems) {
                // The file already fails validation, so every save throws and the relabel waits
                // until it is fixed. Counts at warn; the problems name bundle ids, so debug only.
                Log.describe.warn(
                    "could not add the new seed apps to taxonomy.json: it has \(problems.count) validation problem(s); fix them and relaunch"
                )
                Log.describe.debug("taxonomy.json validation: \(problems.joined(separator: "; "))")
            } catch {
                Log.describe.warn("could not add the new seed apps to taxonomy.json")
                Log.describe.debug("taxonomy merge failed: \(error)")
            }
            let capture = ScreenCaptureService()
            let timeline = TimelineWriter(config: config, db: db, taxonomy: taxonomy)

            // #17: one tracker, shared by everything that can spend. Built before the services
            // so each of them is handed the same gate rather than its own.
            let cost = CostTracker(db: db, config: config)

            // Held rather than built inline: the context sync scheduler feeds it the meetings
            // it just synced, which is what makes capture slow down during a scheduled call.
            let meeting = MeetingDetector()
            // One monitor for both: the scheduler wants the wake, the recorder wants the lock and
            // the sleep, and two sets of observers for the same notifications would be two
            // answers to one question.
            let system = SystemStateMonitor()
            // Counts every switch and title change, so a blocked tab opened and closed again
            // inside one capture is noticed although both ends of it look the same. Started
            // before the scheduler: until it runs, no frame is kept.
            let focusChanges = FocusChangeMonitor()
            focusChanges.start()
            let scheduler = CaptureScheduler(
                config: config,
                db: db,
                capture: capture,
                context: ForegroundContextCollector(config: config),
                focusChanges: focusChanges,
                meeting: meeting,
                system: system,
                costGate: cost,
                // #53. Handed in unconditionally: the snapshotter itself answers nil while
                // Accessibility is not granted, so the tick is unchanged until the user grants it.
                snapshotter: AccessibilitySnapshotter()
            )
            let sessionRecorder = ForegroundSessionRecorder(config: config, db: db, system: system)
            // Every described frame redraws its day; every captured frame wakes the worker rather
            // than leaving it to the 15 s poll.
            scheduler.onTick = { [weak self] result in
                self?.handle(tick: result)
            }
            // Any change the scheduler publishes — state as well as ticks — reaches the menu on
            // the next main-actor turn, which is what keeps "paused" visible within 2 s.
            scheduler.objectWillChange
                .sink { [weak self] in
                    Task { @MainActor in self?.syncSchedulerState() }
                }
                .store(in: &cancellables)

            self.db = db
            self.taxonomy = taxonomy
            self.capture = capture
            self.timeline = timeline
            self.scheduler = scheduler
            self.sessionRecorder = sessionRecorder
            self.cost = cost
            self.eraser = DataEraser(config: config, db: db, timeline: timeline)
            self.disk = DiskBudget(config: config, db: db)
            self.retention = Retention(config: config, db: db)

            // The log comes back before anything can add to it, so a problem raised below lands
            // on top of yesterday's rather than replacing it.
            // The reports were cut (2026-10-05), so a report notice an older build left in the
            // log is dropped rather than kept on the menu with a button that does nothing. A
            // sentence an older build wrote with a dash in it is read back without one.
            state.notices = NoticeStore(db).load()
                .filter {
                    $0.action != .retryDailyReport && $0.action != .retryWeeklyReport
                        && $0.issue != .noAnthropicKey
                }
                .map { notice in
                    Notice(
                        id: notice.id, kind: notice.kind, message: NoEmDash.replaced(notice.message),
                        at: notice.at, action: notice.action, issue: notice.issue,
                        dismissedAt: notice.dismissedAt
                    )
                }

            // A database that had to be replaced is the one failure that must never be quiet:
            // the app is running on an empty history and the old one is still on disk.
            if case let .replacedCorrupt(movedTo, _)? = db.recoveredFrom {
                let name = URL(fileURLWithPath: movedTo).lastPathComponent
                note(error: "The database could not be opened and was moved to \(name). "
                    + "Worklens is recording into a new, empty one.")
                postBanner(
                    title: NotificationCopy.databaseRecoveredTitle,
                    body: NotificationCopy.databaseRecoveredBody(movedTo: name),
                    identifier: "db-recovered",
                    // #149: the banner now offers to reveal the file it is talking about,
                    // rather than naming it and leaving you to go and find it.
                    category: Notifier.databaseCategory,
                    userInfo: [Notifier.Key.path: movedTo],
                    // `note(error:)` above already put the same sentence on the menu.
                    mirrorAsNotice: false
                )
            }

            self.meetingDetector = meeting
            contextSync = AppModel.buildContextSync(config: config, db: db, meeting: meeting)

            // A rejected key cannot be re-derived from the config — only a call can tell. Being
            // here at all is the user saying they changed something, so the line goes and the
            // next failure raises it again.
            clear(.keyRejected)

            // Each key's line is re-derived here rather than remembered: one added since the
            // last launch clears itself, and one taken away raises itself.
            // Being here is the user saying the keys changed, so the queue starts optimistic
            // again (#125) and the frames a rejected key marked `failed` — which nothing else
            // ever un-marks — go back to `pending` so the corrected key can describe them.
            state.describeHealth = .ok
            if let key = config.geminiAPIKey, !key.isEmpty {
                clear(.noGeminiKey)
                let requeued = (try? DescribeQueries(db).requeueRejectedFailures(
                    day: DayBoundaries.dayString(Date())
                )) ?? 0
                if requeued > 0 {
                    Log.describe.info("re-queued \(requeued) frames a rejected key had failed")
                }
                let describer = GeminiClient(apiKey: key, model: config.describeModel)
                let provider = describer.provider
                describe = DescribeWorker(
                    config: config,
                    db: db,
                    taxonomy: taxonomy,
                    describer: describer,
                    cost: cost,
                    onDescribed: { [weak self] day in
                        await timeline.nudge(day: day)
                        // #350: the first real summary hands the sample week over.
                        await self?.sampleWeekSummaryArrived(provider: provider)
                    },
                    healthHandler: { [weak self] health in
                        await self?.describeHealthChanged(health)
                    }
                )
            } else {
                raise(.noGeminiKey)
            }

        } catch {
            // #126: a data directory that will not open is not a bad value, and telling somebody
            // to fix their `.env` when every value in it is fine sends them looking in the wrong
            // place. Its own field, its own sentence, its own remedy.
            state.storageError = "Worklens could not open its data folder at \(config.dataDir.path): \(error)"
            Log.ui.error("could not open the data directory: \(error)")
        }
        render()
    }

    // MARK: Reacting

    private func handle(tick: TickResult) {
        if tick.decision == .describedPending {
            Task { await describe?.nudge() }
        }
        syncSchedulerState()
        Task { await refreshCounters() }
    }

    private func syncSchedulerState() {
        guard let scheduler else { return }
        state.scheduler = scheduler.state
        // #145: the scheduler owns the OS power observers, so this is where the charger reaches
        // the menu — and the describe queue, which is an actor and cannot read a main-actor fact.
        if state.power != scheduler.power {
            state.power = scheduler.power
            let power = scheduler.power
            Task { [weak self] in await self?.describe?.setPower(power) }
        }
        mirrorSessionRecorder(scheduler.state)
        trackPause(scheduler.state)
        trackTimedPause(scheduler.state)
        noteBudgetReached(scheduler.state)
        if state.scheduler == .permissionMissing, screenRecording != .denied {
            screenRecording = .denied
            notifyPermissionLost()
        }
        // "Idle" for the weekly VACUUM means the scheduler has nothing to do — the user is away
        // or the Mac is locked — not that Worklens is stopped. A stopped scheduler is somebody
        // deliberately not recording, and taking the write lock then is just as rude.
        switch state.scheduler {
        case .idle, .locked, .asleep:
            break
        default:
            busySince = Date()
        }
        render()
    }

    /// The recorder runs exactly when capture runs — paused means "record nothing", which is
    /// what `PRIVACY.md` promises. Driven off the scheduler's published state rather than off the
    /// menu actions, so a *timed* pause expiring inside the scheduler resumes the recorder too.
    private func mirrorSessionRecorder(_ state: SchedulerState) {
        guard let sessionRecorder else { return }
        switch state {
        case .stopped:
            sessionRecorder.stop()
        case .paused:
            sessionRecorder.pause()
        default:
            sessionRecorder.isRunning ? sessionRecorder.resume() : sessionRecorder.start()
        }
    }

    // MARK: - The banners the scheduler owns (#149)

    /// The deadline of the timed pause in force, kept so its expiry can be announced. A pause
    /// with no deadline ("until I resume") never runs out on its own and never gets a banner.
    private var timedPauseUntil: Date?

    /// The local day the "budget reached" banner was last posted for, so it is posted once a day
    /// and not once a frame.
    private var budgetBannerDay: String?
    static let budgetBannerDayKey = "budget_banner_day"

    /// Says so when a timed pause runs out, because nothing else does: capture starts again
    /// inside the scheduler, and the only sign of it was the menu-bar icon changing shape for
    /// anyone who happened to be looking at it.
    private func trackTimedPause(_ schedulerState: SchedulerState) {
        if case let .paused(until) = schedulerState {
            timedPauseUntil = until
            return
        }
        let until = timedPauseUntil
        timedPauseUntil = nil
        // Only a pause that ran out, and never on top of a permission incident ending — both
        // rules live in `BannerLatch`, where a test can reach them.
        guard BannerLatch.announcesPauseEnded(
            until: until, now: Date(), permissionIncident: permissionIncident
        ) else { return }
        postBanner(
            title: NotificationCopy.pauseEndedTitle,
            body: NotificationCopy.pauseEndedBody,
            identifier: "pause-expired"
        )
    }

    /// Says so on the day the budget is reached. `CaptureScheduler` sets `.budgetExceeded` per
    /// frame and puts it back to `.running` on the next under-budget one, so a state transition
    /// flaps; the latch is the local day, and it is stored so a relaunch does not repost it.
    private func noteBudgetReached(_ schedulerState: SchedulerState) {
        guard schedulerState == .budgetExceeded else { return }
        if budgetBannerDay == nil, let db {
            budgetBannerDay = (try? AppStateStore(db).get(AppModel.budgetBannerDayKey)) ?? nil
        }
        guard let today = BannerLatch.budgetBannerDay(
            lastPosted: budgetBannerDay, now: Date()
        ) else { return }
        budgetBannerDay = today
        if let db { try? AppStateStore(db).set(AppModel.budgetBannerDayKey, today) }
        postBanner(
            title: NotificationCopy.budgetReachedTitle,
            body: NotificationCopy.budgetReachedBody,
            identifier: "budget-reached"
        )
    }

    // MARK: - Still paused (#113)

    /// When the current pause began, or when it was last reminded about — nil whenever capture is
    /// not paused. A pause now survives a quit and the updater's own restart, so the one thing
    /// left to go wrong is forgetting about it; the clock restarts at launch for a restored one.
    private var pausedSince: Date?

    private func trackPause(_ schedulerState: SchedulerState) {
        if case .paused = schedulerState {
            if pausedSince == nil { pausedSince = Date() }
        } else {
            pausedSince = nil
        }
    }

    /// Every `PAUSE_REMINDER_HOURS` while paused, one notification naming the deadline. Stable
    /// identifier: the second reminder replaces the first rather than stacking up.
    private func remindIfStillPaused() {
        guard case let .paused(until) = state.scheduler, let since = pausedSince else { return }
        guard PauseReminder.isDue(
            since: since, now: Date(), everyHours: config.pauseReminderHours
        ) else { return }
        pausedSince = Date()
        Notifier.post(
            title: PauseReminder.title,
            body: PauseReminder.body(until: until),
            identifier: "pause-reminder"
        )
    }

    func refreshCounters() async {
        guard let db else { return }
        let counts = (try? MenuCounts.today(db: db)) ?? .zero
        state.counts = counts
        // Cheap, and the grant can be revoked from Settings while the app runs.
        refreshAccessibility()
        // #141: whether a source is failing in a way only the user can clear.
        await refreshIntegrationAttention()
        refreshBrowserURLs(db: db)
        lastDescribedAt = try? DescribeQueries(db).lastDescribedAt()
        if let cost {
            // #137: the budget in force, raise included, so the menu, Settings and the gate that
            // actually stops a call can never quote different numbers.
            state.budgetUSD = await cost.budgetUSD
            budgetOverrideUSD = await cost.overrideToday()
        }
        await refreshGoogleReconnect()
        render()
    }

    /// #141: the menu's integration line, and one notification per incident.
    ///
    /// A failure that waiting will fix — a rate limit, a 5xx — is the Integrations tab's to show
    /// and nothing more. A refused token or a revoked grant is not: it never clears itself, and
    /// until this there was no Notifier call site for an integration at all, so a Granola key
    /// revoked on a Tuesday drained context out of the timeline until somebody happened to open
    /// Settings. The notification is posted once per incident — the scheduler remembers that it
    /// was, across relaunches — and both the line and the flag go on the next success.
    func refreshIntegrationAttention() async {
        guard let contextSync else {
            state.integrationsNeedingAttention = []
            return
        }
        // An expired Google grant is actionable too, but `refreshGoogleReconnect` below owns
        // it: it has the button that fixes it and the sentence that explains it. Leaving it in
        // here as well would put the same incident in two menu lines and two notifications.
        let statuses = await contextSync.statusList.filter {
            $0.lastErrorIsActionable && !$0.needsReconnect
        }
        state.integrationsNeedingAttention = statuses.map(\.displayName)
        for status in statuses where status.notifiedFailureAt == nil {
            Notifier.post(
                title: NotificationCopy.integrationAttentionTitle(status.displayName),
                body: NotificationCopy.integrationAttentionBody(status.lastError),
                identifier: "integration-\(status.id.rawValue)"
            )
            await contextSync.markAttentionNotified(status.id)
        }
    }

    /// #139: Google expires the grant behind Calendar every seven days while the
    /// consent screen stays in Testing, and before this the app's whole answer was an error
    /// sentence telling a menu-bar user to run a terminal command.
    ///
    /// Condition-derived, like every other `SetupIssue`: it is asked of the scheduler's typed
    /// `needsReconnect` flag on every refresh, so a successful sync clears it without anyone
    /// remembering to. The banner is the edge into the condition, under a stable identifier, so
    /// a week of paused syncs is one notification and not one every fifteen minutes.
    private func refreshGoogleReconnect() async {
        let paused = await contextSync?.sourcesNeedingReconnect ?? []
        guard !paused.isEmpty else {
            googleReconnectNotified = false
            clear(.googleReconnect)
            return
        }
        raise(.googleReconnect)
        guard !googleReconnectNotified else { return }
        googleReconnectNotified = true
        Notifier.post(
            title: NotificationCopy.googleReconnectTitle,
            body: NotificationCopy.googleReconnectBody(SetupIssue.googleReconnect.message),
            identifier: "google-reconnect"
        )
    }

    func refreshSpendHistory() async {
        guard let db else { return }
        spendHistory = (try? await cost?.summary(days: 30))
            ?? (try? LLMCallStore(db).summary(days: 30))
            ?? []
    }

    /// What `DATA_DIR/screenshots` weighs. A directory walk, so it is called at launch, after a
    /// sweep, and when Settings opens — never on a render.
    func refreshScreenshotBytes() async {
        guard let disk else { return }
        let bytes = disk.totalBytes()
        screenshotBytes = bytes
    }

    /// #125: what Settings → Models & cost says about the describe queue — the menu's sentence
    /// when something is wrong, and a calm one when nothing is.
    var describeHealthLine: String { state.describeHealth.settingsLine() }

    /// #125: `Today at 14:05`, or when there has never been one.
    var lastSummaryLine: String { DescribeHealth.lastSummaryLine(lastDescribedAt) }

    /// `6.3 GB of 20 GB budget` — Settings → Models & cost.
    var screenshotDiskLine: String {
        DiskBudget.line(
            used: screenshotBytes,
            budget: Int64(config.screenshotDiskBudgetGB * Double(DiskBudget.bytesPerGiB))
        )
    }

    func recheckPermissions() {
        Task { [weak self] in
            guard let self else { return }
            // Read before the `capture` guard, not after it: `start()` calls this while the
            // services are still nil, and `postBanner` mirrors a banner onto the menu whenever
            // `notifications` says the banner would not be delivered. Behind the guard, the
            // property sat at its `.notDetermined` default until the +30 s refresh tick — which
            // posts its banners *before* it rechecks — so an authorized user could get a
            // banner and the same sentence as a menu notice.
            self.notifications = await Notifier.authorizationStatus()
            guard let capture = self.capture else { return }
            let state = await capture.permissionState()
            let was = self.screenRecording
            self.screenRecording = state
            self.refreshAccessibility()
            // The stamp that makes "lost" true later. Written the first time the grant is seen,
            // whether it was granted before Worklens existed or a moment ago in the dialog.
            if state == .granted { self.markScreenRecordingGranted() }

            // macOS re-asks for Screen Recording roughly monthly, and a denial is silent: the
            // scheduler simply stops producing frames. One banner per incident, and one when it
            // comes back, is the difference between noticing the same day and noticing in a week.
            switch state {
            case .denied:
                self.notifyPermissionLost()
            case .granted where was == .denied || self.permissionIncident:
                self.notifyPermissionRestored()
            default:
                break
            }
        }
    }

    /// Re-reads the Accessibility grant. No prompt: `AXIsProcessTrusted()` only answers.
    func refreshAccessibility() {
        let trusted = AccessibilityPermission.isTrusted
        accessibilityTrusted = trusted
        state.accessibilityMissing = !trusted
    }

    /// #64: which browsers produced frames today with no URL at all, and could be fixed by
    /// granting Automation. Two cheap reads on the 30 s refresh — one indexed query and one TCC
    /// lookup per browser that appears in it — and, like `refreshAccessibility`, it only ever
    /// asks: `AutomationPermission.status` passes `askUserIfNeeded: false`, so no tick can prompt.
    ///
    /// A browser that is not running is left out. `procNotFound` says nothing about the grant,
    /// and warning about a browser the user closed hours ago would be noise the rest of the day.
    func refreshBrowserURLs(db: Database) {
        guard config.collectBrowserURL else {
            state.browsersMissingURLs = []
            return
        }
        let bundleIDs = (try? CaptureStore(db).browserBundlesWithoutURL(
            day: DayBoundaries.dayString(Date())
        )) ?? []
        var denied: [String] = []
        var notAsked: [String] = []
        for bundleID in bundleIDs {
            let name = AutomationPermission.displayName(forBundleID: bundleID) ?? bundleID
            switch AutomationPermission.status(forBundleID: bundleID) {
            case .denied:
                denied.append(name)
            case .notAsked:
                // #117: the one that can still be answered. macOS lists an app under Automation
                // once it has an answer on file, so "open System Settings" is no help here and
                // Settings → Permissions offers the dialog per browser instead.
                notAsked.append(name)
            case .allowed, .notRunning:
                break
            }
        }
        state.browsersMissingURLs = denied.sorted()
        state.browsersNotAsked = notAsked.sorted()
    }

    /// Shows the system prompt that offers to open Settings, then opens the pane anyway — the
    /// prompt appears at most once per app installation, and the pane is what actually helps.
    /// Only ever called from a button in Settings → Permissions; #53 forbids prompting on launch.
    func requestAccessibility() {
        AccessibilityPermission.request()
        AccessibilityPermission.openSettings()
        refreshAccessibility()
    }

    /// #117: asks macOS for Screen Recording, and only falls back to the System Settings pane
    /// when the answer is still no.
    ///
    /// Opening the pane was the whole of the old affordance, and on a Mac that has never been
    /// asked that pane has no Worklens row to switch on: macOS lists an app there once it has
    /// requested the permission. `CGRequestScreenCaptureAccess()` is what creates the row, and
    /// `ScreenCaptureService` calls it at most once per launch, so a second click after a denial
    /// silently does nothing — which is exactly when the pane is the right place to send someone.
    ///
    /// A grant that lands here does not reach the running process: macOS hands the new answer to
    /// processes that start afterwards, so the notice carries the Relaunch button.
    func requestScreenRecording() {
        guard let capture else {
            ScreenCaptureService.openScreenRecordingSettings()
            return
        }
        Task { [weak self] in
            let granted = await capture.requestPermission()
            guard let self else { return }
            if granted {
                self.markScreenRecordingGranted()
                self.note(notice: ScreenRecordingCopy.relaunchHint, action: .relaunchWorklens)
            } else {
                ScreenCaptureService.openScreenRecordingSettings()
            }
            self.recheckPermissions()
        }
    }

    /// Quits and comes back, in the order that survives `SingleInstance`.
    ///
    /// A detached `/bin/sh` waits for this process to leave the process table and then `open`s
    /// the bundle; only then does the app terminate. Doing it the other way round — asking
    /// `NSWorkspace` for a new instance and then quitting — leaves nothing running at all: the
    /// new copy sees this one still alive, activates it, and exits (`SingleInstance.swift`).
    /// `scripts/update.sh` has used this order since the updater existed; `RelaunchPlan` says why
    /// the wait is on this process's pid rather than on `update.sh`'s `pgrep` pattern.
    func relaunch() {
        guard let bundle = AppModel.bundlePathForRelaunch() else {
            note(error: "This copy of Worklens was not started from an app bundle, so it cannot "
                + "relaunch itself. Quit and start it again.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            RelaunchPlan.script(
                processID: ProcessInfo.processInfo.processIdentifier, bundlePath: bundle
            ),
        ]
        // The helper outlives this process; inherited pipes would only give it somewhere to
        // block once the app is gone.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            note(error: "Could not relaunch: \(error.localizedDescription)")
            return
        }
        Log.ui.info("relaunching")
        NSApp.terminate(nil)
    }

    /// The `.app` this process was started from, or nil for `swift run Worklens`, which has no
    /// bundle to reopen. The Relaunch buttons are hidden in that case rather than failing.
    static func bundlePathForRelaunch() -> String? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return url.path
    }

    var canRelaunch: Bool { AppModel.bundlePathForRelaunch() != nil }

    /// Reads the two persisted permission facts (#117) before the first `recheckPermissions()`,
    /// so the first tick knows whether this is a first run or an outage that is already open.
    private func restorePermissionState() {
        guard let db else { return }
        let store = AppStateStore(db)
        screenRecordingEverGranted =
            ((try? store.get(AppModel.screenRecordingGrantedKey)) ?? nil) != nil
        permissionIncident = ((try? store.get(AppModel.permissionIncidentKey)) ?? nil) != nil
        state.screenRecordingEverGranted = screenRecordingEverGranted
        state.accessibilityAdvisorySkipped = isSkipped(AppModel.skipAccessibilityAdvisoryKey)
        state.browserAdvisorySkipped = isSkipped(AppModel.skipBrowserAdvisoryKey)
    }

    // MARK: - How the last run ended (#156)

    /// Reads the clean-exit marker, says something once if the last run ended badly, then marks
    /// this run as running.
    ///
    /// Called from `start()` and nowhere else, so it happens once per launch: `buildServices()`
    /// runs again on every configuration reload, and checking there would raise a crash notice
    /// every time the user changed a key. Only the app ever writes these markers — the same
    /// binary is every `worklens <subcommand>`, and a `worklens search` that cleared the marker
    /// and exited would manufacture a crash out of a working CLI.
    ///
    /// A planned restart is not a crash: `scripts/update.sh` records one before it SIGTERMs the
    /// app, which is what keeps the app's own unattended update path from crying wolf.
    private func checkPreviousRun() {
        guard let db else { return }
        let markers = RunMarkers(AppStateStore(db))
        let outcome: RunOutcome
        do {
            outcome = try markers.beginRun()
        } catch {
            Log.storage.warn("could not read the run markers: \(error)")
            return
        }
        switch outcome {
        case .firstRun, .clean:
            break
        case .expectedRestart:
            Log.ui.info("the previous run was stopped for a planned restart")
        case let .unexpected(startedAt):
            // One sentence, once per incident: the marker has already been rewritten above, so
            // the next launch after a clean quit says nothing.
            note(
                error: RunOutcomeCopy.unexpectedExitNotice(startedAt: startedAt),
                action: .openLogFile
            )
        }
    }

    /// The last thing `shutdown()` does, after the WAL checkpoint: the marker is only honest if
    /// everything it claims finished has actually finished.
    private func markCleanExit() {
        guard let db else { return }
        do {
            try RunMarkers(AppStateStore(db)).endRunCleanly()
        } catch {
            Log.storage.warn("could not record a clean exit: \(error)")
        }
    }

    /// The button on that notice. Today's file if there is one, the folder otherwise — a crash
    /// just before midnight leaves the interesting lines in yesterday's.
    private func openTodaysLog() {
        let directory = config.logsDir
        let today = FileLog.fileURL(day: DayBoundaries.dayString(Date()), in: directory)
        if FileManager.default.fileExists(atPath: today.path) {
            open(today)
        } else {
            open(directory, creating: true)
        }
    }

    /// Stamps `screen_recording_granted_at` the first time the grant is seen, and never again:
    /// the key's presence is the whole signal, and rewriting it would lose the first date.
    private func markScreenRecordingGranted() {
        guard !screenRecordingEverGranted else { return }
        screenRecordingEverGranted = true
        state.screenRecordingEverGranted = true
        if let db { try? AppStateStore(db).setDate(AppModel.screenRecordingGrantedKey, Date()) }
        render()
    }

    /// Whether one optional-permission line has been silenced.
    func isSkipped(_ key: String) -> Bool {
        guard let db, let raw = (try? AppStateStore(db).get(key)) ?? nil else { return false }
        return raw == "true"
    }

    /// Settings → Permissions → "Don't remind me". Silences one advisory line in the menu and
    /// changes nothing else: the pane still says where the grant stands, and the permission is
    /// still optional either way.
    func setSkipped(_ key: String, _ value: Bool) {
        guard let db else { return }
        if value {
            try? AppStateStore(db).set(key, "true")
        } else {
            try? AppStateStore(db).delete(key)
        }
        state.accessibilityAdvisorySkipped = isSkipped(AppModel.skipAccessibilityAdvisoryKey)
        state.browserAdvisorySkipped = isSkipped(AppModel.skipBrowserAdvisoryKey)
        render()
    }

    /// Posts the "permission missing" banner once per incident. Clicking it opens the Screen
    /// Recording pane — `AppDelegate` routes `Notifier.permissionCategory` there.
    ///
    /// The menu line is raised first and unconditionally: `raise` is idempotent, and a relaunch
    /// into a still-missing grant has to show the problem again even though the notification for
    /// it was posted before the restart (#117).
    private func notifyPermissionLost() {
        raise(
            .screenRecordingDenied,
            message: ScreenRecordingCopy.problemMessage(everGranted: screenRecordingEverGranted)
        )
        guard !permissionIncident else { return }
        permissionIncident = true
        if let db { try? AppStateStore(db).setDate(AppModel.permissionIncidentKey, Date()) }
        Log.capture.warn("Screen Recording permission is missing; notifying and retrying")
        // #246: through `postBanner`, because this is one of the two moments a banner earns the
        // notifications dialog — a grant that has gone is announced by a banner and by nothing
        // else that reaches somebody who is not looking at the menu bar. `mirrorAsNotice` is
        // false: `raise(.screenRecordingDenied)` above is already the menu's line for it.
        postBanner(
            title: ScreenRecordingCopy.notificationTitle(everGranted: screenRecordingEverGranted),
            body: ScreenRecordingCopy.notificationBody(everGranted: screenRecordingEverGranted),
            identifier: "permission-screen-recording",
            category: Notifier.permissionCategory,
            mirrorAsNotice: false,
            moment: .screenRecordingOutage
        )
    }

    private func notifyPermissionRestored() {
        guard permissionIncident else { return }
        permissionIncident = false
        if let db { try? AppStateStore(db).delete(AppModel.permissionIncidentKey) }
        clear(.screenRecordingDenied)
        Log.capture.info("Screen Recording permission is back; capturing again")
        Notifier.post(
            title: NotificationCopy.permissionRestoredTitle,
            body: NotificationCopy.permissionRestoredBody,
            identifier: "permission-screen-recording-restored"
        )
        // The scheduler holds a five-minute retry gate of its own; a frame now proves it works
        // and clears it, rather than leaving the menu wrong for up to five minutes.
        if scheduler?.state == .permissionMissing { captureNow() }
        render()
    }

    /// A Mac that slept through the monthly TCC prompt comes back with no permission and no
    /// tick due for a while — so the wake itself is a reason to look.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckPermissions()
                Task { await self?.refreshCounters() }
            }
        }
    }

    /// Keeps an open reader current, once a minute and only while somebody has it on screen:
    /// the index walks the whole capture history, `readerSelection` survives a window close, and
    /// neither is worth a minute's work for a window nobody is looking at.
    ///
    /// It was the second half of the report scheduler's tick until the reports were cut
    /// (2026-10-05). Nothing is written behind the reader any more, so what moves is today: its
    /// frame counts and its timeline. `ReaderTick.decide` is the whole rule, asserted without a
    /// window.
    private func runReaderTick() async {
        guard readerIsVisible else { return }
        let decision = ReaderTick.decide(
            open: readerSelection, today: DayBoundaries.dayString(Date())
        )
        if decision.refreshIndex { await refreshReaderIndex() }
        readerCache.dropHoldingToday(DayBoundaries.dayString(Date()))
        if decision.rebuildDocument { loadReaderDocument() }
    }

    /// #137: the budget in force today — the configured one, or today's raise when it is higher.
    /// One call site's worth of plumbing so nothing outside `CostTracker` resolves it itself.
    func effectiveBudget() async -> Double {
        await cost?.budgetUSD ?? config.dailyBudgetUSD
    }

    /// #137: raises today's budget to `amount` and puts today's budget-skipped frames back in
    /// the queue. The way out of an over-budget day that does not involve editing a file: the
    /// raise is stored per local day, so tomorrow starts on `DAILY_BUDGET_USD` again.
    func raiseBudgetToday(to amount: Double) {
        guard let cost else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let requeued = try await cost.raiseBudgetToday(to: amount)
                Log.ui.info("budget raised for today; \(requeued) frames requeued")
                self.note(done: requeued == 0
                    ? "Budget raised for today."
                    : "Budget raised for today: \(requeued) screenshot"
                        + "\(requeued == 1 ? "" : "s") back in the queue.")
                await self.refreshCounters()
            } catch {
                self.note(error: "Could not raise today's budget: \(error)")
            }
        }
    }

    /// Posts a banner, and when no banner can be shown says the same thing on the menu (#149).
    ///
    /// Notifications are unavailable outside an app bundle (`swift run Worklens`) and silently
    /// dropped when the user has said "Don't Allow" — or has never been asked, which is where an
    /// install that skipped the welcome's Notifications row stays for good. `Notifier.delivers`
    /// is the one place that decides which statuses reach a screen. `mirrorAsNotice` is
    /// false at the call sites that already raise a notice of their own, so the menu never shows
    /// the same incident twice.
    func postBanner(
        title: String,
        body: String,
        identifier: String,
        category: String? = nil,
        userInfo: [String: String] = [:],
        mirrorAsNotice: Bool = true,
        moment: NotificationMoment = .other
    ) {
        let post = {
            Notifier.post(
                title: title, body: body, identifier: identifier,
                category: category, userInfo: userInfo
            )
        }
        // Read after the dialog rather than before it, so an answered "Allow" is a banner and
        // nothing else, and a "Don't Allow" still leaves the incident on the menu.
        let mirror = { [weak self] in
            guard let self, mirrorAsNotice,
                !Notifier.isAvailable || !Notifier.delivers(self.notifications)
            else { return }
            self.note(notice: "\(title): \(body)")
        }
        // #246: the one place the app asks macOS for Notifications on its own — at the first
        // moment a banner earns the question, and never at launch, during the welcome, or twice.
        // `NotificationConsent` is the whole rule and is tested in `WorklensCore`.
        switch notificationConsent(for: moment) {
        case .post:
            post()
            mirror()
        case .ask:
            recordNotificationAsk()
            Log.ui.info("asking macOS for notifications: \(moment.rawValue) has something to say")
            requestNotifications {
                post()
                mirror()
            }
        case .quiet:
            // Nothing would have been drawn — denied, never asked, or no app bundle at all —
            // so the menu line is the whole of what the user sees.
            mirror()
        }
    }

    /// #150: says "Worklens is back" on the first launch after an update, and only then.
    ///
    /// The key is cleared whatever the comparison decides, so an update that failed and relaunched
    /// the same build says nothing — once, rather than at every launch afterwards.
    private func announceUpdateReturn() {
        guard let db else { return }
        let store = AppStateStore(db)
        let pending = (try? store.get(UpdatePending.key)) ?? nil
        try? store.delete(UpdatePending.key)
        guard let line = UpdatePending.notice(
            pending: pending, running: BuildStamp.current.commit
        ) else { return }
        note(done: line)
    }

    /// Puts a problem on the menu and in the log, and leaves it there. #110 replaced the
    /// ten-minute slot this used to write into: a 07:00 failure nobody was awake for is
    /// still a failure at 09:00, so a problem goes when the user dismisses it, not when a timer
    /// runs out. The default kind is what makes every existing `note(error:)` call still mean
    /// what it meant.
    func note(error message: String, action: NoticeAction? = nil) {
        add(Notice(kind: .problem, message: message, action: action))
        Log.ui.warn(message)
    }

    /// Something that is not going wrong and is not worth keeping — a folder opened because the
    /// file was missing. Gone after `Notice.infoVisibility`.
    func note(notice message: String, action: NoticeAction? = nil) {
        add(Notice(kind: .info, message: message, action: action))
        Log.ui.info(message)
    }

    // MARK: - Activities (#150)

    /// The cancel handles for the activities in `state.activities`, keyed by id. They live here
    /// rather than on `Activity` because `MenuState` is `Equatable` and `Sendable` and a closure
    /// is neither — and because cancelling is an app-side act, not a fact about the menu.
    private var activityCancels: [String: @MainActor () -> Void] = [:]

    /// Registers something that has just started. Replaces an entry with the same id, so a second
    /// press of the same button never draws the row twice.
    func beginActivity(_ activity: Activity, cancel: (@MainActor () -> Void)? = nil) {
        state.activities.removeAll { $0.id == activity.id }
        state.activities.append(activity)
        activityCancels[activity.id] = cancel
        render()
    }

    /// Attaches the handle to an activity that is already registered, for the case where the
    /// thing to cancel does not exist until after the row is up.
    func setActivityCancel(_ id: String, _ cancel: @escaping @MainActor () -> Void) {
        guard state.activities.contains(where: { $0.id == id }) else { return }
        activityCancels[id] = cancel
    }

    /// Takes the row away. Safe to call for something that is already gone.
    func endActivity(_ id: String) {
        state.activities.removeAll { $0.id == id }
        activityCancels[id] = nil
        render()
    }

    /// The menu's Cancel button. Cancelling stops the waiting — it does not un-spend anything the
    /// model has already generated, which is what the notice says out loud.
    func cancelActivity(_ id: String) {
        guard let cancel = activityCancels[id] else { return }
        Log.ui.info("cancelling activity \(id)")
        cancel()
    }

    /// Something the user asked for, finished: a delete, a sweep. Long enough to read, then gone,
    /// so a confirmation never sits in the same slot as a real failure.
    func note(done message: String) {
        add(Notice(kind: .done, message: message))
        Log.ui.info(message)
    }

    /// Raises a condition-backed problem. A dismissed one for the same condition is replaced:
    /// the condition has been re-derived and is still true, so it is worth saying again.
    /// `message` overrides the issue's own sentence where one condition has two true wordings
    /// (#117: Screen Recording never granted versus revoked) or carries a detail only the caller
    /// knows (#122: which folder, which other Mac).
    ///
    /// A live row is left alone only while it still says the same thing: a `DATA_DIR` that moved
    /// from one synced folder to another is the same condition with a different answer, and the
    /// stale sentence would name a folder that is no longer the problem.
    func raise(_ issue: SetupIssue, message: String? = nil) {
        let text = message ?? issue.message
        if state.notices.contains(where: {
            $0.issue == issue && $0.dismissedAt == nil && $0.message == text
        }) { return }
        state.notices.removeAll { $0.issue == issue }
        add(Notice(issue, message: message))
        Log.ui.warn(text)
    }

    /// #125: the describe queue changed its mind about whether it is working.
    ///
    /// Three things follow from one signal. The row itself is `MenuState.describeHealth`, which
    /// is live and goes the moment a frame is summarized again. A refusal that names the key is
    /// also a `SetupIssue`, so it survives a relaunch, reaches the Activity log and carries the
    /// same "Open .env…" button every other key problem does. And the first step *into* `.failing`
    /// posts one notification, under a stable identifier so a long stall is one banner and not one
    /// every fifteen seconds — the edge is the failing one, not the one out of `.ok`, so a stall
    /// reached through `.holding` still gets its banner.
    ///
    /// Only `.failing` notifies. `.holding` is a laptop with the lid shut or a train tunnel: it
    /// clears itself, and a banner for it would be the kind of nagging this app does not do.
    func describeHealthChanged(_ health: DescribeHealth) {
        let was = state.describeHealth
        state.describeHealth = health

        if health.isKeyRejection, let line = health.line() {
            raise(.keyRejected, message: line)
        } else if !health.isKeyRejection {
            // Cleared on anything that is no longer a key rejection, not only on recovery: a 403
            // that becomes a 503 has stopped being about the key, and leaving the old problem row
            // up would contradict the health row sitting right next to it.
            clear(.keyRejected)
        }

        if health.startsStall(after: was), let line = health.line() {
            Notifier.post(
                title: NotificationCopy.describeStalledTitle,
                body: NotificationCopy.describeStalledBody(line),
                identifier: "describe-stall"
            )
        }
        render()
    }

    /// Drops a condition-backed problem, dismissed or not: the condition is gone, so the line is.
    func clear(_ issue: SetupIssue) {
        guard state.notices.contains(where: { $0.issue == issue }) else { return }
        state.notices.removeAll { $0.issue == issue }
        persistNotices()
        render()
    }

    /// The user pressed Dismiss. Kept in the log — the Activity list still shows it, without the
    /// "still open" mark — because hiding it from the menu is not the same as it never happening.
    func dismissNotice(_ id: UUID) {
        guard let index = state.notices.firstIndex(where: { $0.id == id }) else { return }
        state.notices[index].dismissedAt = Date()
        persistNotices()
        render()
    }

    /// Marks the notices you have read on Settings' status line as reviewed, when they are the
    /// kind that seeing is enough for (`Notice.isReviewedBySeeing`). Anything that wants a fix
    /// stays open however many times you look at it.
    func markNoticesSeen(_ ids: Set<UUID>) {
        let now = Date()
        var changed = false
        for index in state.notices.indices
        where ids.contains(state.notices[index].id)
            && state.notices[index].isOpen && state.notices[index].isReviewedBySeeing {
            state.notices[index].dismissedAt = now
            changed = true
        }
        guard changed else { return }
        persistNotices()
        render()
    }

    /// The button a notice carries. One place, so a notice can be persisted as a plain value and
    /// still do something after a relaunch.
    func perform(_ action: NoticeAction) {
        switch action {
        case .openEnvFile: openEnvFile()
        case .openAccountSettings: openSettings(SettingsTarget(.providers))
        case .reloadConfig: reloadConfig()
        case .grantScreenRecording: requestScreenRecording()
        case .grantAccessibility: requestAccessibility()
        case .relaunchWorklens: relaunch()
        // Legacy: filtered out of the log on load, so never on a button (2026-10-05).
        case .retryDailyReport, .retryWeeklyReport: break
        case .syncIntegrations: syncIntegrationsNow()
        case .reconnectGoogle: openSettings(SettingsTarget(.sources))
        case .reconnectClaude: openSettings(SettingsTarget(.assistants))
        case .openLogFile: openTodaysLog()
        }
    }

    private func add(_ notice: Notice) {
        state.notices = NoticeStore.trimmed([notice] + state.notices)
        persistNotices()
        render()
    }

    /// One small row, written where it is changed. The log is thirty short strings, and the
    /// alternative — writing it on quit — loses exactly the crash it would have explained.
    private func persistNotices() {
        guard let db else { return }
        NoticeStore(db).save(state.notices)
    }

    private func render() {
        state.firstRun = AppModel.isFirstRun(config)
        state.captureIntervalSeconds = config.captureIntervalSeconds
        state.meetingIntervalSeconds = config.meetingCaptureIntervalSeconds
        // #137: the effective budget, not the configured one — `render()` runs at the end of
        // every `refreshCounters()`, and reassigning `config.dailyBudgetUSD` here would throw
        // away the raise it had just read from `CostTracker` and leave the menu and Settings
        // quoting the old number while the gate describes again.
        state.budgetUSD = max(config.dailyBudgetUSD, budgetOverrideUSD ?? 0)
        // #145: the setting half of the battery policy; the live half arrives from the scheduler.
        state.batteryMode = config.captureOnBattery
        // #131: nil until the launch gate has run, so the half-second between `init()` and
        // `start()` cannot put "Finish setting up Worklens (0 of 4)" in front of an install that
        // has been capturing for months.
        state.setup = setupDecided ? setupProgress : nil
        menu = MenuModel(state: state)
    }

    // MARK: - Menu actions

    func pause(for duration: TimeInterval?) {
        scheduler?.pause(for: duration)
        syncSchedulerState()
    }

    /// The menu's "Pause" submenu (#136). Picking another duration while paused replaces the
    /// deadline rather than resuming first, which is how a pause is extended.
    func pause(_ choice: PauseChoice) {
        switch choice {
        case .fifteenMinutes, .oneHour:
            pause(for: choice.seconds)
        case .untilTomorrow:
            pauseUntilTomorrow()
        case .untilResumed:
            pause(for: nil)
        }
    }

    /// Pause until the next local midnight — the "and start fresh tomorrow" option.
    func pauseUntilTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        guard let midnight = calendar.nextDate(
            after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else { return pause(for: 12 * 3600) }
        pause(for: midnight.timeIntervalSince(now))
    }

    func resume() {
        scheduler?.resume()
        syncSchedulerState()
    }

    /// Starts the scheduler if "start capturing on launch" was off, otherwise resumes.
    func startOrResume() {
        // Silently doing nothing would be the worst answer: the row may have been dismissed, so
        // re-deriving it puts the explanation back in front of whoever just pressed the button.
        guard let scheduler, !refusedForDataDir() else { return }
        if scheduler.state == .stopped {
            scheduler.start()
            // Starting from the menu or the hotkey is the same intent as the Settings toggle.
            // Without this, someone who turned the toggle off and started by hand is stopped
            // again on the next launch, with nothing having said so (#113).
            setStartCapturingOnLaunch(true)
        } else {
            scheduler.resume()
        }
        syncSchedulerState()
    }

    func captureNow() {
        guard !refusedForDataDir() else { return }
        Task { [weak self] in
            guard let self, let scheduler = self.scheduler else { return }
            let result = await scheduler.captureNow()
            if result.decision == .error {
                self.note(
                    error: "Capture failed: check Screen Recording permission.",
                    action: .grantScreenRecording
                )
            } else if let skipped = MenuModel.captureNowSkippedLine(result.decision) {
                // A forced tick still collects nothing for its own reasons — a blocklisted app
                // in front, a locked screen, a window with no text — and each of those wrote a
                // row with no frame. Saying "captured" there would claim the one thing this app
                // must never claim falsely.
                self.note(done: skipped)
            } else {
                // #136: it said nothing when it worked, so "Capture now" was a button with no
                // answer. One passing line, the same one the menu uses for everything else that
                // finished.
                self.note(done: "Captured this screen.")
            }
            await self.refreshCounters()
        }
    }

    /// "Sync integrations now" (#19): one round over every configured source, ignoring backoff.
    /// Failures land on the menu's error line, where the user can see them without opening
    /// Settings.
    func syncIntegrationsNow() {
        guard let contextSync, hasConfiguredIntegrations else {
            // #135: Settings can set one up now, so that is where this points — the old line sent
            // the user to a text file the app is perfectly able to write for them.
            openSettings(SettingsTarget(.sources))
            return
        }
        // #150: a sync can take the better part of a minute against four sources, and before
        // this the only sign it was happening was the notice at the end of it.
        beginActivity(Activity(id: AppModel.syncActivityID, kind: .sync, label: "Syncing integrations"))
        let task = Task { [weak self] in
            defer { self?.endActivity(AppModel.syncActivityID) }
            let results = await contextSync.syncNow()
            let failures = results
                .compactMap { source, result -> String? in
                    guard case let .failure(error) = result else { return nil }
                    // #141: the scheduler holds all four sources and fails the unset ones, so
                    // without this a user with only Granola never sees anything but "Sync
                    // failed". "Set it up" is the Integrations tab's sentence, not the menu's.
                    guard !ContextSyncError.isNotConfigured(error) else { return nil }
                    return "\(source.rawValue): \(ContextSyncScheduler.describe(error))"
                }
                .sorted()
            if failures.isEmpty {
                // #141: a manual sync used to report only when it went wrong, so the ordinary
                // answer to pressing "Sync integrations now" was nothing at all.
                let inserted = results.values.reduce(0) { total, result in
                    guard case let .success(sync) = result else { return total }
                    return total + sync.inserted
                }
                // #150: `warnings` describe a partial success — a page that failed, a scope
                // that is missing for one call — and were dropped on the floor here, so a sync
                // that half worked read exactly like one that worked. Counts and the source's own
                // sentence; never a title, never a URL.
                let warnings = results.values.reduce(into: [String]()) { all, result in
                    guard case let .success(sync) = result else { return }
                    all.append(contentsOf: sync.warnings)
                }
                let synced = "Synced · \(inserted) new event\(inserted == 1 ? "" : "s")"
                if warnings.isEmpty {
                    self?.note(done: synced)
                } else {
                    self?.note(notice: synced + " · " + warnings.sorted().joined(separator: "; "))
                }
            } else {
                self?.note(
                    error: "Sync failed: " + failures.joined(separator: "; "),
                    action: .syncIntegrations
                )
            }
            await self?.refreshCounters()
        }
        setActivityCancel(AppModel.syncActivityID) { task.cancel() }
    }

    /// The id of the one sync activity: pressing "Sync all now" twice is one sync, not two rows.
    static let syncActivityID = "sync"
    /// The prefix every configuration reload's activity id is built from.
    ///
    /// Not one fixed id: reloads *queue* (`enqueueReload` chains them rather than cancelling),
    /// and under one id the first reload's `defer` took the row away while the second was still
    /// tearing services down and building them back up. The row and the busy glyph cleared
    /// early, and `AutoUpdater` — which holds off while `isBusy` — was free to quit and relaunch
    /// in the middle of a rebuild. One id per queued reload, so the row stands until the queue
    /// drains.
    static let reloadActivityID = "reload"
    private var reloadCount = 0
    private func nextReloadActivityID() -> String {
        reloadCount += 1
        return "\(AppModel.reloadActivityID)-\(reloadCount)"
    }

    /// One confirmation alert, with the keyboard doing the safe thing. Returns true when the
    /// user asked for the action.
    ///
    /// #154: each of the three alerts this replaces made its action button the Return button, so
    /// Return spent money you had just been told was over budget, or restarted the app —
    /// and the one place anybody had noticed, the erase alert, fixed it by clearing
    /// `defaultButtonCell`, which left Return doing nothing and each site's
    /// `runModal() == .alertFirstButtonReturn` easy to get backwards. One helper answering a Bool
    /// means no call site touches
    /// `alertFirstButtonReturn` and no call site can order its buttons wrongly.
    ///
    /// The action button keeps its macOS place — added first, so rightmost — and is reached with
    /// ⌘↩; Escape cancels, as it already did. Return is deliberately inert: AppKit gives a button
    /// one key equivalent and `NSWindow.defaultButtonCell` overwrites it, so "Return cancels" and
    /// "Escape cancels" cannot both be true of a two-button alert, and Escape is the one a Mac
    /// user already reaches for. What matters is that neither key performs the action.
    func confirm(
        title: String, message: String, confirmTitle: String, destructive: Bool = false
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let action = alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))
        action.hasDestructiveAction = destructive
        action.keyEquivalent = "\r"
        action.keyEquivalentModifierMask = [.command]
        // Adding the buttons leaves the action button as the window's `defaultButtonCell`, and
        // that Return path fires the cell without consulting the ⌘ mask — so without this line
        // plain Return still erases, spends or restarts. Clearing it is what keeps Return inert.
        alert.window.defaultButtonCell = nil
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Opening things

    /// The `.env` the app actually read, creating one under Application Support when there is
    /// none — an editor open on nothing helps nobody, and an editor open on a file that lists
    /// every key with its default helps rather more (#116).
    func openEnvFile() {
        let url = AppModel.envFileURL()
        _ = try? FirstRunEnv.createIfMissing(at: url)
        open(url)
    }

    /// #116: with no configuration file anywhere, write one. Someone who installed the app
    /// rather than the checkout has no `.env.example` to copy and no `make install-env` to run,
    /// so "Open .env…" would otherwise open a file they have to invent. The template lists every
    /// key commented out at its default, with the two API keys blank and waiting; nothing here
    /// changes any value, and an existing file is never touched.
    private func writeStarterEnvIfNeeded() {
        guard state.configError == nil, configProvenance.noFilesFound else { return }
        do {
            guard let url = try FirstRunEnv.createIfMissing() else { return }
            Log.ui.info("first run: wrote a starter configuration file at \(url.path)")
        } catch {
            Log.ui.error("could not write a starter .env: \(error)")
        }
    }

    /// #129: writes down which configuration file this launch was told to read, so
    /// `scripts/launch.sh` — and so "Update and restart…" — can relaunch into the same one.
    /// Only a real `WORKLENS_ENV_FILE` override is recorded; without one the file is removed,
    /// because naming the App Support `.env` here would promote it above `settings.json`
    /// instead of reproducing anything. A failure here costs the script nothing but its
    /// fallback, so it is logged and let go.
    private func recordLaunchEnvironment() {
        do {
            let override = configProvenance.devOverrideActive
                ? configProvenance.devOverrideFile?.url
                : nil
            if let written = try LaunchEnv.write(envFile: override) {
                Log.ui.info("launch environment recorded at \(written.path)")
            }
        } catch {
            Log.ui.warn("could not record the launch environment: \(error)")
        }
    }

    /// Settings → General → Storage: what the database file weighs, or nil before it exists.
    var databaseBytes: Int64? {
        let path = config.databaseURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    /// `1.2 GB` — the database file, WAL excluded (it is checkpointed away, and a number that
    /// moved with it would read as noise).
    var databaseDiskLine: String {
        guard let bytes = databaseBytes else { return "no database yet" }
        return DiskBudget.humanBytes(bytes)
    }

    /// Settings → Advanced → the provenance list: opens one of the files that were consulted.
    /// Only ever a path `ConfigProvenance` produced, which is `Config`'s list and nobody else's.
    func openConfigFile(_ url: URL) { open(url) }

    /// Reveals a folder or file in Finder rather than opening it (#129): a data folder full of
    /// SQLite files is something to look at, not something to open.
    func showInFinder(_ url: URL, creating: Bool = false) {
        if creating {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// No Gemini key: the app is installed but has never been set up. Drives the
    /// menu's first-run line, and is re-derived on every `render()` so it goes away the moment a
    /// key arrives.
    static func isFirstRun(_ config: Config) -> Bool {
        (config.geminiAPIKey ?? "").isEmpty
    }

    static func envFileURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["WORKLENS_ENV_FILE"], !explicit.isEmpty {
            return Config.expandPath(explicit, cwd: Config.currentDirectory)
        }
        let appSupport = Config.appSupportEnvURL()
        if FileManager.default.fileExists(atPath: appSupport.path) { return appSupport }
        let local = Config.currentDirectory.appendingPathComponent(".env")
        return FileManager.default.fileExists(atPath: local.path) ? local : appSupport
    }

    private func open(_ url: URL, creating: Bool = false) {
        if creating {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Settings writes (#108)

    /// Writes one key to Worklens's own settings file and rebuilds the stack around it.
    ///
    /// The settings file is the app's layer: it is validated before it is written, it outranks
    /// both `.env` files, and it loses to the process environment and `WORKLENS_ENV_FILE`, so a
    /// worktree or a script that pinned a key keeps it. Throws a readable `ConfigError` or
    /// `SettingsStoreError` for the control that called it to show.
    func applySetting(_ key: String, _ value: String) throws {
        try settings.set(key, value)
        Log.ui.info("settings: \(key) changed")   // names only — a value could be an API key
        reloadConfig()
    }

    /// Removes a key from the settings file, so the layer below it wins again.
    func clearSetting(_ key: String) throws {
        try settings.remove(key)
        Log.ui.info("settings: \(key) cleared")
        reloadConfig()
    }

    // MARK: Blocklists (#128)

    /// Adds one entry to one blocklist and reloads the stack around it, so the next tick already
    /// respects it. Throws a readable `BlocklistError` for the control that called it to show.
    ///
    /// Only the list is logged, never the entry: a blocked host is a site you use, which is
    /// exactly the kind of thing the log must not learn.
    func block(_ raw: String, in list: Blocklist) throws {
        try blocklists.block(raw, in: list)
        blocklistOverlay = blocklists.load()
        Log.ui.info("blocklists: one entry added to \(list.configKey)")
        reloadConfig()
    }

    /// Removes one entry, whichever layer put it there — an entry of yours goes away, one from
    /// `.env` or from the built-in defaults gets a tombstone in the overlay.
    func unblock(_ raw: String, in list: Blocklist) throws {
        try blocklists.unblock(raw, in: list, base: configProvenance.base(of: list))
        blocklistOverlay = blocklists.load()
        Log.ui.info("blocklists: one entry removed from \(list.configKey)")
        reloadConfig()
    }

    /// Undoes such a removal.
    func restoreBlock(_ raw: String, in list: Blocklist) throws {
        try blocklists.restore(raw, in: list)
        blocklistOverlay = blocklists.load()
        Log.ui.info("blocklists: one removal undone in \(list.configKey)")
        reloadConfig()
    }

    // MARK: Accounts (#124)

    /// The two API keys, as Settings → Models & cost → Accounts draws them.
    var accountRows: [AccountRow] {
        Accounts.rows(config: config, provenance: configProvenance)
    }

    /// Saves a typed API key to the settings file and rebuilds the stack, which is what clears
    /// the `noGeminiKey` problem and starts describing again.
    ///
    /// The value is trimmed and refused only when it cannot be a key at all; a wrong-looking
    /// prefix is a caption, not a refusal (`Accounts.shapeWarning`). Nothing here logs the value:
    /// `applySetting` logs the key's *name*.
    func setCredential(_ provider: KeyProvider, _ typed: String) throws {
        let value = Accounts.normalize(typed)
        if let problem = Accounts.entryError(value) { throw AccountEntryError(problem) }
        try applySetting(provider.envKey, value)
    }

    /// Forgets a key Worklens stored. Whatever a `.env` sets then wins again — which is why the
    /// row re-reads its source rather than assuming the key is now missing.
    func clearCredential(_ provider: KeyProvider) throws {
        try clearSetting(provider.envKey)
    }

    /// Asks the provider whether it knows this key: one free models-list `GET`, no tokens, and a
    /// $0 row in `llm_calls` so the call is as auditable as any other (#124). Nil when no key is
    /// set — there is nothing to ask about.
    func verifyCredential(_ provider: KeyProvider) async -> AccountVerification? {
        guard let key = provider.value(in: config), !key.isEmpty else { return nil }
        let cost = self.cost
        let verifier = AccountVerifier(record: { call in
            do { try await cost?.record(call) } catch {
                Log.ui.warn("could not record the key check in the ledger: \(error)")
            }
        })
        let verification = await verifier.verify(provider, key: key)
        // The status, never the key and never the provider's own words about the request.
        Log.ui.info("verified \(provider.envKey): \(verification.line)")
        return verification
    }

    // MARK: Config reload

    /// Runs one reload after the last one has finished, never beside it (#135).
    ///
    /// Applying a configuration suspends: the old services are stopped and the new ones started,
    /// and both are `await`s that let the main actor run the next queued reload. Two of them
    /// interleaved would have one task nil `contextSync` immediately after the other had assigned
    /// its freshly started scheduler to it — and a started `ContextSyncScheduler` holds itself
    /// alive inside its own loop, so that instance would sync forever with nothing able to stop
    /// it. One Save in the integrations sheet writes two keys, so this is a single button press
    /// away rather than a race you would have to hunt for.
    ///
    /// Chained rather than cancel-and-replace: a reload cancelled mid-`shutdown()` is exactly the
    /// half-torn-down stack "parse first, tear down second" (#126) exists to prevent.
    private func enqueueReload(_ body: @escaping @MainActor () async -> Void) {
        let previous = reloadTask
        reloadTask = Task { @MainActor in
            await previous?.value
            await body()
        }
    }

    /// Re-reads `.env` and rebuilds every service around it. The scheduler is stopped and
    /// restarted, so a changed `CAPTURE_INTERVAL_SECONDS` takes effect without a relaunch.
    ///
    /// **Parse first, tear down second** (#126). This used to shut every service down and nil
    /// them *before* it read the new file, so one typo left a running app with no capture, no
    /// describe worker and no scheduler — and the only way back was a relaunch. Now a failed
    /// reload changes nothing at all: no shutdown, no `configError`, the same interval, the same
    /// scheduler state. It raises a notice naming the key and the file, and capture keeps going.
    func reloadConfig() {
        // #150: a reload tears down and rebuilds every service and said nothing at all — not
        // while it ran, and not when it finished. Both halves now: a row while it happens, and a
        // notice naming the cadence that came out of it, which is the setting a reload is
        // usually being run for.
        let activityID = nextReloadActivityID()
        beginActivity(Activity(
            id: activityID, kind: .reload, label: "Reloading configuration"
        ))
        enqueueReload { [weak self] in
            guard let self else { return }
            defer { self.endActivity(activityID) }
            switch ConfigReload.outcome(of: { try Config.loadWithProvenance() }) {
            case let .keepRunning(message, _):
                // Nothing above this line touched a service, and nothing below it will.
                self.note(error: message, action: .openEnvFile)
                self.render()
            case let .rebuild(config, provenance):
                // #135: a change confined to the context keys rebuilds only the context sync
                // scheduler, so editing an integration never interrupts capture.
                if self.canReloadContextOnly(into: config) {
                    await self.applyContextReload((config, provenance))
                } else {
                    await self.applyReloaded((config, provenance))
                }
                self.note(done: "Configuration reloaded · capturing every "
                    + MenuModel.cadence(self.config.captureIntervalSeconds))
            }
        }
    }

    /// "Use defaults for these keys and start" — the degraded menu's and the banner's way out.
    ///
    /// A lenient load: only the keys whose values do not parse are dropped, every other value in
    /// the file is kept, and the built-in default stands **for this session only**. Nothing is
    /// written anywhere — `.env` is the source of truth and still says exactly what it said, so
    /// the next launch is the real one and the fix is still owed.
    func startOnDefaults() {
        enqueueReload { [weak self] in
            guard let self else { return }
            switch ConfigReload.outcome(of: { try Config.loadWithProvenance(lenient: true) }) {
            case let .keepRunning(message, _):
                self.note(error: message, action: .openEnvFile)
                self.render()
            case let .rebuild(config, provenance):
                await self.applyReloaded((config, provenance), announcing: false)
                guard self.state.configError == nil, self.state.storageError == nil else { return }
                self.note(notice: ConfigReload.startedOnDefaultsMessage(droppedKeys: provenance.keysUsingDefaults))
                self.render()
            }
        }
    }

    /// Tears the old stack down and builds a new one around a configuration that has already
    /// parsed. Only ever called with a `Config` in hand (#126).
    ///
    /// `async` rather than fire-and-forget: the caller has to be able to see whether the new
    /// stack came up before it says anything about it (#126). `announcing: false` is for the
    /// caller that has a more specific thing to say than "Configuration reloaded".
    private func applyReloaded(
        _ loaded: (config: Config, provenance: ConfigProvenance),
        announcing: Bool = true
    ) async {
        // `wasRunning == false` carries two different meanings and only one of them is "stopped
        // on purpose". Either the old stack was deliberately not capturing, or there was no old
        // stack at all: a degraded startup never reaches `buildServices()`, so `scheduler` is nil
        // here, and the whole promise of "Use defaults for these keys and start" is that capture
        // begins now. Stopping in that second case is how the button used to build a stack and
        // leave it idle (#126).
        let hadStack = self.scheduler != nil
        let wasRunning = self.scheduler.map { $0.state != .stopped } ?? false
        await self.shutdown()

        self.cancellables.removeAll()
        self.db = nil
        self.taxonomy = nil
        self.capture = nil
        self.scheduler = nil
        self.sessionRecorder = nil
        self.describe = nil
        self.timeline = nil
        self.contextSync = nil
        self.meetingDetector = nil
        self.cost = nil
        self.eraser = nil
        self.disk = nil
        self.retention = nil

        self.config = loaded.config
        self.configProvenance = loaded.provenance
        // #128: the overlay is part of the stack being rebuilt — `loadWithProvenance` has already
        // applied it to `config`, and this keeps the Settings rows reading the same file.
        self.blocklistOverlay = self.blocklists.load()
        Log.configure(self.config)
        self.state.storageError = nil
        self.applyConfigDiagnostics(loaded.provenance)

        self.buildServices()
        // #145: the rebuilt worker starts at `.mains`, and `state.power` still holds the old
        // stack's reading — so the equality guard in `syncSchedulerState()` would never tell it
        // the Mac is on battery. Push it once, unconditionally.
        if let power = self.scheduler?.power {
            self.state.power = power
            Task { [weak self] in await self?.describe?.setPower(power) }
        }
        self.pauseHotkey = nil
        self.openHotkey = nil

        self.started = false
        self.start()
        if ConfigReload.stopsAfterRebuild(hadStack: hadStack, wasRunning: wasRunning) {
            self.scheduler?.stop()
            self.sessionRecorder?.stop()
            self.syncSchedulerState()
        }
        // #135: every pane reading derived state knows it is stale, whichever path got here.
        self.configGeneration += 1
        Log.ui.info("configuration reloaded; interval \(self.config.captureIntervalSeconds)s")
        guard self.state.configError == nil, self.state.storageError == nil else { return }
        if announcing { self.note(notice: ConfigReload.reloadedMessage(self.config)) }
        self.render()
    }

    /// The one place a context sync scheduler is built, so the full rebuild and the context-only
    /// one (#135) cannot drift apart. Nil only when this build knows no sources at all.
    private static func buildContextSync(
        config: Config, db: Database, meeting: MeetingDetector
    ) -> ContextSyncScheduler? {
        let sources = ContextSources.all(config: config)
        guard !sources.isEmpty else { return nil }
        return ContextSyncScheduler(
            sources: sources,
            db: db,
            config: config,
            onMeetings: { events in await meeting.setContextEvents(events) },
            outputs: OutputSync.forConfig(config, db: db),
            agents: AgentSessionSync.forConfig(config, db: db)
        )
    }

    /// Whether a reload can be confined to the context sources instead of replacing the stack.
    ///
    /// Only with a stack already up: a degraded start has no database and no capture to preserve,
    /// and must take the full path so `buildServices()` runs at all.
    private func canReloadContextOnly(into config: Config) -> Bool {
        guard db != nil, meetingDetector != nil, scheduler != nil else { return false }
        return ConfigReload.onlyContextChanged(from: self.config, to: config)
    }

    /// Rebuilds *only* `contextSync` (#135). Capture, the describe worker, the timeline and every
    /// timer around them are left exactly as they are.
    ///
    /// This is what makes Settings → Integrations usable: pasting a Granola key used to tear the
    /// whole stack down and start it again, which dropped the frame in flight and re-armed every
    /// schedule because a key the capture path never reads had changed. It is reached only when
    /// `ConfigReload.onlyContextChanged` says nothing outside the context section moved, so every
    /// service left standing is still holding the values it was built with.
    private func applyContextReload(
        _ loaded: (config: Config, provenance: ConfigProvenance)
    ) async {
        // Taken out of the field first and stopped from the local: what is stopped is then always
        // the instance that was just removed, and nothing is nil'd that something else could have
        // filled while this was suspended (`enqueueReload` makes that impossible, and this keeps
        // it impossible if a second caller is ever added).
        let previous = contextSync
        contextSync = nil
        await previous?.stop()

        self.config = loaded.config
        self.configProvenance = loaded.provenance
        Log.configure(self.config)
        applyConfigDiagnostics(loaded.provenance)

        if let db, let meetingDetector {
            contextSync = AppModel.buildContextSync(config: config, db: db, meeting: meetingDetector)
        }
        if let contextSync { await contextSync.start() }

        configGeneration += 1
        Log.ui.info("context sources reloaded; capture was not interrupted")
        note(notice: ConfigReload.contextReloadedMessage(config))
        render()
    }

    // MARK: Integrations (#135)

    /// Whether any context source has the credentials it needs — what the menu's "Sync
    /// integrations now" is gated on.
    ///
    /// `contextSync != nil` was the old gate and was always true: `ContextSources.all` returns
    /// four sources whatever the configuration says, so the menu offered a sync round that could
    /// only ever do nothing.
    var hasConfiguredIntegrations: Bool {
        !ContextSources.configured(config: config).isEmpty
    }

    /// The setup sheet's Test button: one cheap call to the source, nothing written.
    ///
    /// The pasted value is passed straight through and never logged — only the verdict is, and the
    /// provider's own sentence goes to the sheet rather than to the log, because it could quote
    /// the request.
    func testIntegration(_ source: ContextSource, credential: String) async -> IntegrationTester.Outcome {
        let outcome = await IntegrationTester().test(source, credential: credential)
        Log.ui.info("tested \(source.rawValue): \(outcome.verdict)")
        return outcome
    }

    /// Puts a failed load's errors where the menu and the Settings banner read them (#126).
    private func applyConfigError(_ error: Error) {
        let configError = error as? ConfigError
        state.configError = configError?.summary ?? "\(error)"
        state.configErrorDetails = configError?.sentences ?? ["\(error)"]
        state.configErrorFile = configError?.file?.path ?? AppModel.envFileURL().path
    }

    /// Clears a stale error and carries a successful load's advisory lines through (#126).
    private func applyConfigDiagnostics(_ provenance: ConfigProvenance) {
        state.configError = nil
        state.configErrorDetails = []
        state.configErrorFile = nil
        state.configWarnings = provenance.warningLines
    }

    // MARK: - Housekeeping (#18)

    /// The quarter-hourly pass: the cost day rollover, the screenshot disk budget, the day's
    /// project learning, the one-off relabel of apps a seed revision added (#312), and the
    /// weekly `VACUUM` when the app has been quiet long enough to afford it.
    ///
    /// Deliberately one loop rather than four timers. All four are cheap, none is urgent, and
    /// a single 15-minute wake-up is easier to reason about than four that drift into each other.
    private func runHousekeeping() async {
        if let cost {
            let retired = await cost.tick()
            if retired > 0 { await refreshCounters() }
        }
        await sweepScreenshots()
        await ageOutHistory()
        learnProjectsIfDue()
        await relabelAppsIfDue()
        await vacuumIfIdle()
    }

    /// Folds the last week's project hints into the Projects list, once per local day
    /// (`ProjectCatalog.learnIfDue`). It ran before each daily report until the reports were cut
    /// (2026-10-05); Settings → Log's "Learn from recent days" still runs it by hand. A failure
    /// is logged and tried again on the next pass.
    private func learnProjectsIfDue() {
        guard let catalog = projectCatalog else { return }
        do {
            guard let change = try catalog.learnIfDue(), !change.isEmpty else { return }
            Log.ui.info(
                "projects: +\(change.addedProjects.count) new, "
                    + "+\(change.addedAliases.values.reduce(0) { $0 + $1.count }) aliases"
            )
        } catch {
            Log.ui.warn("could not update the project list: \(error)")
        }
    }

    /// #312: moves past frames of apps the seed newly lists to their own key and rebuilds those
    /// days, once per seed revision. Counts only in the log line.
    private func relabelAppsIfDue() async {
        guard let db, let taxonomy, let timeline else { return }
        do {
            let repair = AppLabelRepair(db: db, taxonomy: taxonomy)
            let done = try await repair.relabelIfDue { _ = try await timeline.rebuild(day: $0) }
            guard let done else { return }
            Log.ui.info("app labels: \(done.frames) frames moved, \(done.days.count) days rebuilt")
        } catch {
            Log.ui.warn("could not relabel past frames; trying again on the next pass")
            Log.ui.debug("relabel failed: \(error)")
        }
    }

    /// Deletes what is older than `RETENTION_DAYS` (#144). A no-op at the default 0, which is
    /// why it can sit on the same quarter-hourly pass as the disk budget: it costs one count
    /// and no writes when there is nothing to age out.
    ///
    /// The notice says what survived, because that is the half a reader worries about: the
    /// timelines for those days are still there, and a pass never rebuilds them from the frames
    /// it just deleted.
    private func ageOutHistory() async {
        guard let retention else { return }
        do {
            let sweep = try retention.sweep()
            guard sweep.didAnything else { return }
            await refreshCounters()
            let days = sweep.days.count
            var sentence = "Deleted \(days) day\(days == 1 ? "" : "s") older than "
                + "\(config.retentionDays) days: \(sweep.frames) "
                + "screenshot\(sweep.frames == 1 ? "" : "s"). "
            sentence += config.retentionKeepReports
                ? "Timelines for those days are untouched."
                : "Their timelines went too, as RETENTION_KEEP_REPORTS asks."
            note(done: sentence)
        } catch {
            note(error: "Could not delete the history older than \(config.retentionDays) days: \(error)")
        }
    }

    /// Brings `DATA_DIR/screenshots` back under budget, oldest whole day first.
    private func sweepScreenshots() async {
        guard let disk else { return }
        do {
            let sweep = try disk.sweep()
            screenshotBytes = sweep.bytesAfter
            guard sweep.didAnything else { return }
            note(done: "Freed \(DiskBudget.humanBytes(sweep.freedBytes)) of screenshots "
                + "(\(sweep.daysDeleted.count) day\(sweep.daysDeleted.count == 1 ? "" : "s")) "
                + "to stay under the \(config.screenshotDiskBudgetGB) GB budget. "
                + "Descriptions and timelines are untouched.")
        } catch {
            note(error: "Could not prune old screenshots: \(error)")
        }
    }

    /// `VACUUM` at most weekly, and only after ten minutes of the app having nothing to do —
    /// it rewrites the whole file and holds the write lock while it does.
    private func vacuumIfIdle() async {
        guard let db else { return }
        let idleFor = busySince.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard idleFor >= AppModel.vacuumIdleRequirement else { return }

        let appState = AppStateStore(db)
        let last = (try? appState.getDate(AppModel.lastVacuumKey)) ?? nil
        if let last, Date().timeIntervalSince(last) < AppModel.vacuumInterval { return }

        let before = db.fileBytes(dataDir: config.dataDir)
        do {
            try db.vacuum()
            try? appState.setDate(AppModel.lastVacuumKey, Date())
            let after = db.fileBytes(dataDir: config.dataDir)
            Log.storage.info(
                "vacuumed the database: \(DiskBudget.humanBytes(before)) → \(DiskBudget.humanBytes(after))"
            )
        } catch {
            Log.storage.warn("VACUUM failed: \(error)")
        }
    }

    // MARK: - The hotkeys (#16, #252)

    /// Registers the stored hotkey, or `⌥⇧P`. A combination another app already owns fails
    /// loudly rather than silently: the Settings row says so and offers to record another.
    func registerPauseHotkey() {
        let spec = storedPauseHotkey() ?? HotkeySpec.defaultPause
        guard !clashesWithOwnHotkey(spec, slot: .pause) else {
            pauseHotkeyClashesWithOpen = true
            return
        }
        pauseHotkeyClashesWithOpen = false
        let ok = GlobalHotkey.shared.register(spec, slot: .pause) { [weak self] in
            self?.togglePauseFromHotkey()
        }
        pauseHotkey = ok ? spec : nil
        if !ok {
            note(error: "The pause hotkey \(spec.display) is taken by another app: "
                + "pick a different one in Settings → Privacy.")
        }
    }

    func storedPauseHotkey() -> HotkeySpec? {
        guard let db else { return nil }
        return (try? AppStateStore(db).getCodable(HotkeySpec.pauseKey)) ?? nil
    }

    /// Stores a new hotkey and registers it. Passing nil restores `⌥⇧P`.
    ///
    /// A combination the open shortcut already holds is not stored at all: it could never be
    /// registered, and persisting it would lose the working binding on the next launch too.
    func setPauseHotkey(_ spec: HotkeySpec?) {
        guard !clashesWithOwnHotkey(spec ?? HotkeySpec.defaultPause, slot: .pause) else {
            pauseHotkeyClashesWithOpen = true
            objectWillChange.send()
            return
        }
        store(spec, under: HotkeySpec.pauseKey)
        registerPauseHotkey()
        objectWillChange.send()
    }

    /// What the hotkey does: pause if anything is being recorded, resume if not. One key for
    /// both directions, because the thing you want when you reach for it is "the other one".
    private func togglePauseFromHotkey() {
        guard let scheduler else { return }
        switch scheduler.state {
        // #149: two answers, not three. "Worklens resumed" and "Worklens started"
        // described the same outcome under one notification identifier, so pressing
        // the key twice replaced one banner with the other and read as two events.
        case .paused, .stopped:
            startOrResume()
            announce(
                NotificationCopy.capturingTitle,
                body: NotificationCopy.capturingBody,
                title: NotificationCopy.capturingTitle
            )
        default:
            pause(.untilResumed)
            announce(
                NotificationCopy.pausedTitle,
                body: NotificationCopy.pausedBody,
                title: NotificationCopy.pausedTitle
            )
        }
    }

    /// What the hotkey says back (#136). Pressing a key with no menu open and no window in front
    /// used to be answered by a notification alone, so with notifications denied — which is a
    /// perfectly ordinary setting for an app like this — nothing at all happened on screen.
    ///
    /// Three channels, in order of how much they can be relied on: the menu's own notice line,
    /// which is always there the next time the menu is opened; the notification, when it is
    /// allowed; and a VoiceOver announcement, which is best-effort — an announcement posted by a
    /// background `LSUIElement` app is not reliably spoken while another app is frontmost.
    private func announce(_ phrase: String, body: String, title: String) {
        note(notice: "\(phrase): \(body)")
        Notifier.post(title: title, body: body, identifier: "pause-toggle")
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: phrase,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    // MARK: - Erasing (#16)

    /// "Delete last 10 minutes…" and "Delete last hour…". Counts first, asks, then erases.
    func eraseRecent(minutes: Int) {
        guard let eraser else { return note(error: "No data directory is open.") }
        let range = eraser.recentRange(minutes: minutes)
        let label = minutes < 60
            ? "the last \(minutes) minutes"
            : "the last \(minutes / 60) hour\(minutes == 60 ? "" : "s")"
        erase(range: range, label: label, eraser: eraser)
    }

    /// Settings → Privacy → "Delete data for a date range…", inclusive of both days.
    /// `confirmed`: #286's Privacy page asks inline, with the same count, before it calls this;
    /// every other caller gets the alert.
    func eraseDays(from: String, to: String, confirmed: Bool = false) {
        guard let eraser else { return note(error: "No data directory is open.") }
        guard let range = eraser.dayRange(from: from, to: to) else {
            // docs/copy.md: Worklens is never "I".
            return note(error: "Worklens could not read \(from)-\(to) as a pair of dates.")
        }
        erase(range: range, label: from == to ? from : "\(from) to \(to)", eraser: eraser, confirmed: confirmed)
    }

    /// How many screenshots `eraseDays(from:to:)` would delete — the number the inline confirm
    /// names. Nil when the days do not parse or no data directory is open.
    func eraseCount(from: String, to: String) -> Int? {
        guard let eraser, let range = eraser.dayRange(from: from, to: to) else { return nil }
        return try? eraser.count(from: range.from, to: range.to)
    }

    private func erase(range: (from: Date, to: Date), label: String, eraser: DataEraser, confirmed: Bool = false) {
        let frames = (try? eraser.count(from: range.from, to: range.to)) ?? 0
        guard frames > 0 else {
            return note(notice: "Nothing recorded in \(label): nothing to delete.")
        }
        guard confirmed || confirmErase(frames: frames, label: label) else { return }

        // #150: an erase over a wide range walks every screenshot on disk. It already said what
        // it deleted; what it never said was that it was still going.
        let id = "erase:\(label)"
        beginActivity(Activity(id: id, kind: .erase, label: "Deleting \(label)"))
        Task { [weak self] in
            guard let self else { return }
            defer { self.endActivity(id) }
            do {
                let summary = try await eraser.erase(from: range.from, to: range.to)
                self.note(done: "Deleted \(summary.sentence). "
                    + "What those calls cost stays in the ledger.")
                await self.refreshCounters()
                await self.refreshScreenshotBytes()
            } catch {
                self.note(error: "Could not delete \(label): \(error)")
            }
        }
    }

    private func confirmErase(frames: Int, label: String) -> Bool {
        confirm(
            title: String(
                format: L10n.plural(
                    count: frames,
                    one: "Delete %lld screenshot from %%@?",
                    other: "Delete %lld screenshots from %%@?"),
                label),
            message: String(
                localized: "The screenshots, their descriptions and the timeline for that stretch are removed for good. What the model calls cost stays in the ledger, so the budget keeps adding up.",
                comment: "Alert body"),
            confirmTitle: String(localized: "Delete", comment: "Alert button"),
            destructive: true
        )
    }

    // MARK: - Launch at login (#18)

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = LaunchAtLogin.set(on)
        objectWillChange.send()
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.state()
    }

    func openLoginItemsSettings() { LaunchAtLogin.openLoginItemsSettings() }

    /// Opens `PRIVACY.md`: the copy inside this bundle first (#153), then the checkout this
    /// build came from, then GitHub.
    ///
    /// The bundled copy is the point of the change. This used to look in the *process working
    /// directory*, which for an app launched from the Finder is `/` — so the local branch never
    /// matched for the only kind of install that has no checkout, and the document that says what
    /// Worklens does with your screen was reachable only through a URL on a private repository.
    func openPrivacyDoc() { openHelp(.privacy) }

    /// Any of the documents `scripts/bundle.sh` ships, resolved bundle → checkout → GitHub.
    func openHelp(_ doc: HelpDoc) {
        NSWorkspace.shared.open(doc.url(inCheckout: AppModel.repoRoot))
    }

    /// `DATA_DIR/logs`, where `FileLog` writes `worklens-YYYY-MM-DD.log`, opened rather than
    /// described.
    func openLogFolder() { showInFinder(config.logsDir, creating: true) }

    /// Settings → General → Updates' **Check now** (#153). Asks what `origin/main` points at and
    /// says so — it starts nothing whatever the answer, because "Update and restart…" beside it
    /// is the button that does. It works with `AUTO_UPDATE_ENABLED=false`, where there is no
    /// poller to ask.
    func checkForUpdates() {
        guard let repo = AppModel.repoRoot else {
            updateCheckLine = "This copy of Worklens can't update itself."
            updateOffered = false
            return
        }
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        updateCheckLine = nil
        Task {
            let facts = await AutoUpdater.check(
                repo: repo, runningCommit: BuildStamp.current.commit
            )
            checkingForUpdates = false
            updateCheckLine = AutoUpdatePolicy.manualCheckLine(facts)
            updateOffered = AutoUpdatePolicy.offersUpdate(facts)
        }
    }

    /// Opens `docs/user/troubleshooting.md` (#142) — the checked-out copy when this build came
    /// from a checkout that still has the page, GitHub otherwise, which is the same answer
    /// `HelpLink` gives the CLI. Pass an anchor to land on one symptom.
    /// Qualified: SwiftUI has a `HelpLink` view of its own, so the bare name is ambiguous
    /// anywhere in this target.
    func openTroubleshooting(_ link: WorklensCore.HelpLink? = nil) {
        let bundled = HelpDoc.bundledResources
        let url =
            link?.url(bundledIn: bundled, inCheckout: AppModel.repoRoot)
            ?? WorklensCore.HelpLink.pageURL(bundledIn: bundled, inCheckout: AppModel.repoRoot)
        NSWorkspace.shared.open(url)
    }

    /// Where the bundled app sends someone with no `PRIVACY.md` beside it. `scripts/bundle.sh`
    /// stamps the repository it built from, so a fork's build opens the fork's copy; only a build
    /// with no stamp at all — `swift run`, or a bundle assembled outside a checkout — falls back
    /// to this repository. A remote that is not a web URL (a local mirror) is ignored.
    static var privacyDocURL: String {
        let stamped = BuildStamp.current.repositoryURL.flatMap { $0.hasPrefix("http") ? $0 : nil }
        return "\(stamped ?? AppModel.fallbackRepositoryURL)/blob/main/PRIVACY.md"
    }

    static let fallbackRepositoryURL = "https://github.com/Matheus-F-Scatolin/worklens"

    // MARK: - Updating in place

    /// The checkout this app was built from, when there is one — `WLRepoPath` if the bundle
    /// carries it, the bundle's grandparent otherwise. `CheckoutLocator` has the whole rule and
    /// the reasons; it lives in `WorklensCore` because this answer decides whether the app can
    /// update itself at all.
    static let repoRoot: URL? = CheckoutLocator.resolve(
        stampedPath: BuildStamp.current.repoPath,
        bundleURL: Bundle.main.bundleURL,
        isCheckout: { CheckoutLocator.looksLikeCheckout($0) }
    )

    /// The menu item: confirm, then run the script with `--gui` so a failure opens the log.
    func updateAndRestart() {
        guard let repo = AppModel.repoRoot, confirmUpdate(repo: repo) else { return }
        runUpdateScript(arguments: ["--gui"], announce: true)
    }

    /// Hands the whole pull → build → sign → relaunch round trip to `scripts/update.sh` and gets
    /// out of its way. The script builds first and only then quits this app, so a compile error
    /// leaves the running build alone.
    ///
    /// `--gui` opens `build/update.log` when anything fails, which is the only way to report a
    /// failure to someone whose app is halfway through quitting — and exactly the wrong thing for
    /// the auto-update poll, which nobody asked for: it passes `--log` instead and a window
    /// never appears on its own.
    func runUpdateScript(arguments: [String], announce: Bool) {
        guard let repo = AppModel.repoRoot else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repo.appendingPathComponent("scripts/update.sh").path] + arguments
        process.currentDirectoryURL = repo
        // The script outlives this process and redirects itself to build/update.log; inherited
        // pipes would only give it somewhere to block once the app is gone.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            // #150: the commit that is running right now, so the next launch can tell whether the
            // update actually landed. Written before the script can quit us; the app has no other
            // chance, and the icon is about to vanish for a minute or two.
            if let db, let commit = BuildStamp.current.commit {
                try? AppStateStore(db).set(UpdatePending.key, commit)
            }
            try process.run()
            if announce { note(notice: "Updating: Worklens will quit and come back on its own.") }
        } catch {
            note(error: "Could not start the update: \(error.localizedDescription)")
        }
    }

    // MARK: - Which build is this

    /// The menu's version row: `#105 · 0ae882e · updated 3 hours ago`, from the stamp
    /// `scripts/bundle.sh` left in `Info.plist` — the commit that is *running*, not whatever the
    /// checkout has moved on to.
    var versionLine: String { BuildStamp.current.menuLine() }

    // MARK: Today's card (#159)

    /// Today's numbers — the menu's tally row (#231) — or nil until the first read finishes.
    @Published private(set) var today: TodaySnapshot?

    /// The read in flight, so opening and closing the menu repeatedly starts one query.
    private var todayTask: Task<Void, Never>?

    /// Asks for today's numbers, if the cached ones are older than `TodaySnapshot.cacheSeconds`.
    ///
    /// Called from `AppModel.menuWillOpen()` — when the menu is *opened* — and deliberately not
    /// from the 30 s refresh loop. Even this narrow version is a table read, and
    /// `StatsService.daily` (the only other route to these four numbers) is six full-day scans
    /// plus a ledger query; running either every 30 s all day is the overhead PLAN §1.6 rules
    /// out. The read itself runs off the main actor — `Database` is `Sendable` — so a slow disk
    /// cannot stutter the menu.
    func refreshTodaySnapshot() {
        if let today, !today.isStale() { return }
        guard todayTask == nil, let db else { return }
        let timeZone = TimeZone.current
        let day = DayBoundaries.dayString(Date(), timeZone: timeZone)
        let spend = state.counts.spendUSD
        let budget = state.budgetUSD
        todayTask = Task { [weak self] in
            let snapshot = await AppModel.readToday(
                db: db, day: day,
                spendUSD: spend, budgetUSD: budget, timeZone: timeZone
            )
            self?.today = snapshot
            self?.todayTask = nil
        }
    }

    /// The read, off the main actor: `nonisolated` and `async`, so it runs on the generic
    /// executor rather than blocking the actor that drew the menu. `Database` is `Sendable`.
    private nonisolated static func readToday(
        db: Database,
        day: String,
        spendUSD: Double,
        budgetUSD: Double,
        timeZone: TimeZone
    ) async -> TodaySnapshot {
        let blocks = (try? ActivityBlockStore(db).fetch(day: day)) ?? []
        return TodaySnapshot.make(
            day: day, blocks: blocks, spendUSD: spendUSD, budgetUSD: budgetUSD,
            timeZone: timeZone, locale: .autoupdatingCurrent
        )
    }

    private func confirmUpdate(repo: URL) -> Bool {
        confirm(
            title: String(localized: "Update Worklens and restart?", comment: "Alert"),
            message: String(
                localized: "Worklens closes and opens again by itself in about a minute.",
                comment: "Alert body"),
            confirmTitle: String(localized: "Update", comment: "Alert button")
        )
    }

    // MARK: app_state toggles

    func shouldStartCapturing() -> Bool {
        guard let db else { return false }
        // Absent means yes: a fresh install should start working without a visit to Settings.
        let stored = (try? AppStateStore(db).get(AppModel.startOnLaunchKey)) ?? nil
        return stored != "false"
    }

    func setStartCapturingOnLaunch(_ value: Bool) {
        guard let db else { return }
        try? AppStateStore(db).set(AppModel.startOnLaunchKey, value ? "true" : "false")
        objectWillChange.send()
    }

    /// #147: the pinned Dock icon as `app_state` remembers it, applied at launch. Absent means
    /// off: a Dock icon only while a window is open.
    private func restoreDockIcon() {
        guard let db else { return }
        let stored = (try? AppStateStore(db).get(AppModel.dockIconKey)) ?? nil
        showInDock = stored == "true"
        applyDockIcon()
    }

    /// Settings → General → "Keep Worklens in the Dock".
    func setShowInDock(_ value: Bool) {
        guard showInDock != value else { return }
        showInDock = value
        if let db { try? AppStateStore(db).set(AppModel.dockIconKey, value ? "true" : "false") }
        applyDockIcon()
    }

    /// A pinned tile has no window of its own, so it is `applicationShouldHandleReopen` in
    /// `WorklensApp.swift` that makes clicking it front the home window — the same thing the ⌥⇧W
    /// shortcut does (#252). Unpinning takes the tile away as soon as no window is open.
    private func applyDockIcon() {
        DockPresence.shared.pinned = showInDock
    }

    /// The appearance `app_state` remembers, applied at launch before any window opens.
    private func restoreAppearance() {
        guard let db else { return }
        appearance = AppearanceChoice(stored: (try? AppStateStore(db).get(AppModel.appearanceKey)) ?? nil)
        applyAppearance()
    }

    /// Settings → General → "Appearance".
    func setAppearance(_ value: AppearanceChoice) {
        guard appearance != value else { return }
        appearance = value
        if let db { try? AppStateStore(db).set(AppModel.appearanceKey, value.rawValue) }
        applyAppearance()
    }

    /// `nil` hands the choice back to the system, which is also what an app that never set it gets.
    private func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - The welcome window (#131)

    /// The `Window(id:)` the welcome lives in. `WorklensApp` declares the scene with this id,
    /// the same way the reader's is declared, and `openWindow(id:)` fronts it.
    static let setupWindowID = "setup"

    /// `onboarded_at`, cached. Nil means the sequence has never been completed on this Mac —
    /// or, for one launch, that a configuration error left no database to read it from.
    private(set) var onboardedAt: Date?
    /// The page the launch gate brought the window back to (#246), or nil when it opened at
    /// page one. It is what the resumed page's one confirming line hangs off, and `setupMove`
    /// clears it the moment the user goes anywhere else.
    @Published var setupResumedPage: SetupPage?
    /// True from the launch gate until the welcome is finished: capture is held back, and the
    /// window is not re-opened by a configuration reload that comes through `start()` again.
    private(set) var setupPending = false
    /// False until the launch gate has run once, so `render()` says nothing about setup before
    /// there is anything true to say.
    private var setupDecided = false
    /// Whether the welcome window is on screen, reported by `SetupWindowView`. It is what stops
    /// the launch-time retry below once SwiftUI has finally accepted the request.
    private(set) var setupWindowVisible = false

    /// The required steps and the date behind them, as the menu and the window read
    /// them. Derived every time rather than remembered: a key added in Settings or a grant made
    /// in System Settings has to move this without anything having to remember to update it.
    var setupProgress: SetupProgress {
        SetupProgress(
            screenRecording: screenRecording == .granted,
            geminiKey: !(config.geminiAPIKey ?? "").isEmpty,
            onboardedAt: onboardedAt
        )
    }

    /// The launch gate: show the welcome, write `onboarded_at` under an existing install, or do
    /// nothing. `SetupGate.decide` is the whole rule and lives in `WorklensCore`, where both of
    /// its awkward cases are unit-tested.
    ///
    /// Called from `start()`, which a configuration reload runs again — so this is also where a
    /// key that was finished while `db` was nil finally lands on disk.
    private func startSetupIfNeeded() {
        var hasCaptures = false
        var hasStartOnLaunchRow = false
        var savedPage: SetupPage?
        var storedAppearance: String?
        if let db {
            let store = AppStateStore(db)
            persistDeferredSetupKeys(store)
            onboardedAt = (try? store.getDate(AppModel.onboardedKey)) ?? nil
            // #246: the page a relaunch interrupted. A name this build does not have — one of
            // #131's five — answers nil and so starts again from page one.
            savedPage = SetupPage.stored((try? store.get(AppModel.setupPageKey)) ?? nil)
            hasCaptures = (try? CaptureStore(db).hasAny()) ?? false
            hasStartOnLaunchRow = ((try? store.get(AppModel.startOnLaunchKey)) ?? nil) != nil
            storedAppearance = (try? store.get(AppModel.appearanceKey)) ?? nil
        }
        setupDecided = true
        let decision = SetupGate.decide(
            savedPage: savedPage,
            onboardedAt: onboardedAt,
            hasCaptures: hasCaptures,
            hasStartOnLaunchRow: hasStartOnLaunchRow,
            databaseOpen: db != nil
        )
        // #357 second pass: a new install is light from its first window on, and its first page
        // asks. An install set up before that page, which never chose, keeps the system's.
        if let fresh = AppearanceChoice.firstRunDefault(
            stored: storedAppearance, welcomeShows: decision.showsWelcome, databaseOpen: db != nil
        ) {
            setAppearance(fresh)
        }
        switch decision {
        case .nothing:
            break
        case .recordSilently:
            markOnboarded()
            Log.ui.info("this install predates the welcome window; recorded as already set up")
        case .show:
            // A reload re-enters `start()`; the window is already open and capture is already
            // being held, so there is nothing to do a second time.
            guard !setupPending else { break }
            setupPending = true
            Log.ui.info("first run: the welcome window opens before anything is captured")
            openSetupWhenTheSceneIsReady()
        case let .resume(page):
            // #246: the relaunch macOS forces for Screen Recording used to cost the user every
            // page they had done. The page name is all this restores — the grant and the keys
            // are read live, as they always were.
            guard !setupPending else { break }
            setupPending = true
            Log.ui.info("first run continues: the welcome window comes back where it was left")
            openSetupWhenTheSceneIsReady(resuming: page)
        }
        render()
    }

    /// Writes the setup date that was only ever in memory, which is what a launch with a
    /// broken `.env` leaves behind: the window is shown and can be finished with no database to
    /// write to, and the reload that fixes the configuration comes back through here.
    private func persistDeferredSetupKeys(_ store: AppStateStore) {
        if let onboardedAt, ((try? store.get(AppModel.onboardedKey)) ?? nil) == nil {
            try? store.setDate(AppModel.onboardedKey, onboardedAt)
        }
    }

    /// Asks for the window until it is on screen, and then stops asking.
    ///
    /// `start()` runs inside `applicationDidFinishLaunching`, and a SwiftUI `openWindow(id:)`
    /// that early is dropped without a word — the scene graph is not taking requests yet. That
    /// is the half of the review note's warning that survives: the *action* is reachable (the
    /// menu-bar item's own label hands it over, and `pendingWindowID` holds the request until it
    /// does), but the moment is too early. So the request is repeated a few times a second apart
    /// until `SetupWindowView` reports that it appeared, and then abandoned — never a loop, and
    /// never an `NSWindowController` competing with the scene idiom the reader already uses.
    private func openSetupWhenTheSceneIsReady(attempts: Int = 8, resuming page: SetupPage? = nil) {
        guard !setupWindowVisible else { return }
        if let page { resumeSetup(on: page) } else { openSetup() }
        guard attempts > 1 else {
            Log.ui.warn("the welcome window did not open; it is on the menu as \(SetupCopy.menuItem)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + AppModel.setupOpenRetryDelay) {
            [weak self] in
            self?.openSetupWhenTheSceneIsReady(attempts: attempts - 1, resuming: page)
        }
    }

    /// How long to wait before asking for the window again while it has not appeared.
    static let setupOpenRetryDelay: TimeInterval = 0.4

    /// Opens the welcome window on page 1, light or dark — the menu's "Set up Worklens…", Settings → General's
    /// "Show welcome again", and a first launch with nothing behind it all come here. Whoever
    /// asked for it asked to be walked through, so the stored page goes with it: "show me the
    /// welcome again" means from the beginning (#246).
    func openSetup() {
        clearSetupPage()
        setupPage = .appearance
        openWindow(id: AppModel.setupWindowID)
    }

    /// Opens it where it was left, with the one line the resumed page carries (#246). Only the
    /// launch gate calls this, and only after `SetupGate.decide` has answered `resume`.
    private func resumeSetup(on page: SetupPage) {
        // #352: a quit in the middle of the tour asked for no grant, so there is none to report.
        setupResumedPage = takeInterruptedWelcomeTour() ? nil : page
        setupPage = page
        openWindow(id: AppModel.setupWindowID)
    }

    /// Page 5's "Start capturing": the one thing in the whole sequence that starts the capture
    /// loop, and the thing that writes `onboarded_at`.
    func finishSetup() {
        markOnboarded()
        setupPending = false
        // #246: nothing left to come back to, and the gate answers `nothing` from here on.
        clearSetupPage()
        startOrResume()
        render()
    }

    /// `SetupWindowView` reporting that it appeared or went away — the same hook the reader uses.
    ///
    /// Appearing is what stops the launch-time retry. Going away without the last page having
    /// been pressed writes nothing: the next launch offers the window again, and until then
    /// capture stays off unless the user asks for it, which the menu's own "Start capturing"
    /// does.
    func setupWindow(isVisible: Bool) {
        setupWindowVisible = isVisible
        Log.ui.info("welcome window \(isVisible ? "on screen" : "closed")")
        guard !isVisible, setupPending else { return }
        Log.ui.info("the welcome window was closed before it was finished")
    }

    /// Stamps `onboarded_at` once. With no database the date is held in memory and written by
    /// `persistDeferredSetupKeys` when one opens.
    private func markOnboarded() {
        guard onboardedAt == nil else { return }
        let now = Date()
        onboardedAt = now
        if let db { try? AppStateStore(db).setDate(AppModel.onboardedKey, now) }
    }

    /// Settings → Permissions' **Ask macOS for notifications…**, and the one banner that earns
    /// the dialog on its own (#246).
    ///
    /// The only place in the app that raises it (#131): macOS asks once, and it should be a
    /// question somebody pressed a button to be asked — or one asked at the moment a banner
    /// would have paid off, which is what `postBanner` uses `thenPost` for: the banner goes out
    /// after the answer is in, so the thing that earned the question is not the thing the
    /// dialog swallowed.
    /// Reads the notification status now, for a banner posted at launch: until the first
    /// `recheckPermissions()` lands, `notifications` is its `.notDetermined` default, and a
    /// once-ever banner decided against that default would be spent without being drawn.
    func refreshNotificationStatus() async {
        notifications = await Notifier.authorizationStatus()
    }

    func requestNotifications(thenPost banner: (@MainActor () -> Void)? = nil) {
        Task { [weak self] in
            await Notifier.requestAuthorization()
            guard let self else { return }
            self.notifications = await Notifier.authorizationStatus()
            banner?()
        }
    }

    // MARK: - The reader (#134)

    // Stored state only. Every method behind the reader lives in `AppModel+Reader.swift`; a
    // stored property cannot follow it, because an extension holds none. That is also why
    // nothing below is `private` or `private(set)` any more: a member the reader's own file
    // cannot write is a member that would have had to stay here. `AppModel+Reader.swift` is the
    // only thing in the app that writes any of it.

    /// The `Window(id:)` the reader lives in. `WorklensApp` declares the scene with this id and
    /// `openWindow(id:)` fronts it.
    static let readerWindowID = "reader"

    /// The sidebar: weeks newest first, days newest first inside them.
    @Published var readerWeeks: [ReaderWeek] = []
    /// How much of the history the sidebar has loaded, and what is behind it (#244). The reader
    /// pages through the days now; the fixed 120-day limit this replaces made day 121 unreachable
    /// from the window and cost a group over the whole `captures` table to produce.
    @Published var readerPaging = ReaderPaging()
    /// What the sidebar is pointing at. Setting it loads the detail pane.
    @Published var readerSelection: ReaderSelection? {
        didSet {
            guard oldValue != readerSelection else { return }
            if case let .day(day)? = readerSelection { readerFocusDay = day }
            loadReaderDocument()
        }
    }
    /// Which rail item the window is on (reader redesign). Today shows `readerFocusDay`; Weeks
    /// shows the week around it.
    @Published var readerPlace: ReaderPlace = .today
    /// The last day the reader was on, so Weeks → Today lands back on it.
    var readerFocusDay: String?
    @Published var readerDocument: ReaderDocument?
    @Published var readerLoading = false
    /// False until the index has been read once. Without it the window flashes the "nothing
    /// yet" state on every open, a moment before the days arrive.
    @Published var readerIndexLoaded = false
    /// Whether the reader window is on screen. `ReaderView` owns it — a `Window(id:)` closing
    /// takes nothing model-side with it, so without this the reader tick would keep rebuilding
    /// the index and the selected day's document for the life of the process.
    @Published var readerIsVisible = false
    var readerEntries: [String: DayIndexEntry] = [:]
    var readerLoad: Task<Void, Never>?
    /// Pages already built, and the ones either side of the open page built ahead, so a step
    /// lands at once instead of after a rebuild.
    var readerCache = ReaderDocumentCache()
    /// Builds in flight, by page, so a step onto a page still being built ahead waits for that
    /// build rather than starting a second.
    var readerBuilds: [ReaderSelection: Task<ReaderDocument?, Never>] = [:]

    // MARK: - The sample week (#349, #350)

    // Stored state only; `AppModel+SampleWeek.swift` holds every method and is the only writer.

    /// The reader is showing the invented sample week rather than your own days.
    @Published var isShowingSampleWeek = false {
        // A page read from one database is never drawn over the other's.
        didSet { if oldValue != isShowingSampleWeek { resetReaderCache() } }
    }
    /// The sample's own database, open while it is shown. Never the ledger, never handed to
    /// anything but the reader.
    var sampleWeekDB: Database?
    /// The handoff to your first real summary has happened (or this install predates the sample).
    /// Read once at launch, so a summary does not cost an `app_state` read each.
    var sampleWeekHandedOff = true
    /// The one sample build in flight. A second show waits on it rather than rebuilding the same
    /// folder under it.
    var sampleWeekBuild: Task<Database, Error>?
    /// The folder's removal after the handoff, which a later build waits for.
    var sampleWeekRemoval: Task<Void, Never>?

    /// The taxonomy's resolvers come along, the way the MCP `stats` tool builds it: without them the
    /// category and project bars fall back to raw keys.
    ///
    /// Left here rather than moved with the reader's methods: #217's screenshot list reads the
    /// day's per-app minutes through it too, and a shared service factory living in the reader's
    /// own file would have the dependency the wrong way round.
    func statsService(_ db: Database) -> StatsService {
        guard let taxonomy else { return StatsService(db) }
        return StatsService(
            db, category: taxonomy.categoryResolver, projects: { taxonomy.projects },
            ignoredDomains: { taxonomy.current.ignoredDomains ?? [] }
        )
    }

    // MARK: Scenes (#112)

    // `openWindow` is a *View* environment action: SwiftUI offers a model no way to reach a
    // scene, so the one view that always exists — the menu-bar item's own label — hands its copy
    // over from its body and everything model-side goes through here. Nothing else in the app
    // captures it: one route, one place to fix it. (#286 removed the `Settings` scene, and with it
    // the `openSettings` action this used to hold beside it.)
    private var openWindowAction: ((String) -> Void)?
    /// A window asked for before SwiftUI had handed over the action that opens one (#131). The
    /// welcome window is opened from `start()`, which runs long before any menu is opened, so
    /// "nothing happened" is not an acceptable answer here.
    private var pendingWindowID: String?

    /// Called from the menu-bar item's own label, which is evaluated at launch — that is what
    /// makes a window openable before the menu has ever been opened, and since #231 it is the
    /// only caller. Deliberately touches no `@Published` state: publishing while SwiftUI is drawing
    /// the body that publishes is a runtime warning and a redraw loop.
    func installSceneActions(openWindow: @escaping (String) -> Void) {
        openWindowAction = openWindow
        guard let pending = pendingWindowID else { return }
        pendingWindowID = nil
        // Off this turn: opening a window from inside the body evaluation that installed the
        // action is the same reentrancy the comment above is about.
        DispatchQueue.main.async { [weak self] in self?.openWindow(id: pending) }
    }

    /// Shows Settings in the reader window, on `target` when one is named and on General when
    /// not, and fronts that window, opening it first if it was closed (#286). Settings does not
    /// remember the last section: every plain door opens on General.
    ///
    /// Every door into Settings comes through here: the gear on the rail, ⌘, from anywhere, the
    /// menu's "Settings…", `worklens settings --tab`, `SettingsReveal` from a second launch, and
    /// the remedy buttons that used to name a pane of the old window.
    func openSettings(_ target: SettingsTarget? = nil) {
        settingsSection = target?.section ?? .general
        settingsHighlight = target?.anchor
        frontHomeWindow()
    }

    /// The same, for a whole section.
    func openSettings(_ section: SettingsSection) {
        openSettings(SettingsTarget(section))
    }

    /// Esc on the Settings page, or a click on any rail place: back to the reading place you were
    /// on, which `readerPlace` never stopped holding.
    func closeSettings() {
        settingsSection = nil
        settingsHighlight = nil
    }

    /// The "Saved" toast, or another one-line confirmation, at the foot of the Settings page.
    func settingsToast(_ text: String) {
        settingsToast = SettingsToast(id: (settingsToast?.id ?? 0) + 1, text: text)
    }

    /// Fronts the auxiliary `Window(id:)` scene with this id — see the scene convention in
    /// `docs/architecture.md`.
    func openWindow(id: String) {
        guard let openWindowAction else {
            // #131: remembered rather than dropped. `installSceneActions` opens it the moment
            // SwiftUI hands over the action.
            pendingWindowID = id
            Log.ui.info("no window action installed yet; \(id) will open as soon as there is one")
            return
        }
        DockPresence.shared.windowWillOpen()
        NSApp.activate(ignoringOtherApps: true)
        openWindowAction(id)
    }
}
