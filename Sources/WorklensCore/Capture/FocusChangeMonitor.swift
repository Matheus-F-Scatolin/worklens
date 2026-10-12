import AppKit
import ApplicationServices
import Foundation

// MARK: - The mark (pure)

/// One reading of a `FocusChangeObserving`: how many app switches and front-window, focus, tab
/// and title changes it has heard so far, and how much it is able to hear.
///
/// `CaptureRevalidation` compares the context before and after a capture, and that alone misses
/// a round trip: switch from an allowed tab to a blocked one while the picture is being taken,
/// then back, and both ends look the same although the picture is of the blocked tab. Two marks
/// with the same `generation` around the capture mean nothing moved in between, there and back
/// included.
public struct FocusChangeMark: Sendable, Equatable {
    public enum Reach: Sendable, Equatable {
        /// App switches, and through Accessibility the front app's window, focus and title changes.
        case full
        /// App switches only: Accessibility is not granted, so a title change inside the app
        /// cannot be heard and the before/after comparison is all there is for those.
        case activationsOnly
        /// Accessibility is granted but the front app is not being watched (yet, or at all).
        /// Nothing captured under this reach is kept.
        case blind
    }

    /// Moves on every change heard. Only equality between two marks means anything.
    public var generation: UInt64
    /// The app being watched, as the OS last said it was in front.
    public var pid: pid_t?
    public var reach: Reach

    public init(generation: UInt64, pid: pid_t?, reach: Reach) {
        self.generation = generation
        self.pid = pid
        self.reach = reach
    }
}

/// What the scheduler needs to notice a change it would otherwise only see the ends of. A
/// protocol so the scheduler's tests can switch tabs mid-capture without a desktop.
public protocol FocusChangeObserving: Sendable {
    /// The count as of now. Nil when nothing is being watched at all, which the scheduler treats
    /// as "something may have changed": a frame is never kept on a nil.
    func mark() -> FocusChangeMark?
}

// MARK: - The live monitor

/// Counts app switches (`NSWorkspace`, no permission needed) and, when Accessibility is granted,
/// the front app's focused-window, main-window, focused-element, title and page-load changes
/// through an `AXObserver`.
///
/// The observer lives on a thread of its own, so a change is counted the moment the app reports
/// it rather than whenever the main actor next gets to it, and an app that answers slowly stalls
/// that thread and not the menu. Nothing is logged: the count is all that is kept, never which
/// app, window or title moved.
public final class FocusChangeMonitor: FocusChangeObserving, @unchecked Sendable {
    /// Registered on the application element, which hears them from every element in the app.
    static let appNotifications: [String] = [
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXTitleChangedNotification,
        kAXWindowCreatedNotification,
        "AXLoadComplete",
    ]
    /// Without at least one of these the app is not really watched: a tab switch is heard as a
    /// title change or a focus change, a window switch as a focused-window change.
    static let essentialNotifications: Set<String> = [
        kAXFocusedWindowChangedNotification,
        kAXTitleChangedNotification,
    ]
    /// Registered on the focused window as well, for apps that report a title change only to
    /// observers of the element whose title it is.
    static let windowNotifications: [String] = [
        kAXTitleChangedNotification,
        kAXUIElementDestroyedNotification,
    ]

    private let lock = NSLock()
    // Guarded by `lock`.
    private var started = false
    private var generation: UInt64 = 0
    private var frontPID: pid_t?
    private var watchedPID: pid_t?
    private var installPending = false
    private var runLoop: CFRunLoop?

    // Touched only on the observer thread.
    private var thread: Thread?
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var windowElement: AXUIElement?

    private var activationToken: NSObjectProtocol?

    public init() {}

    /// Starts counting. Call once, from the main actor, before the scheduler's first tick.
    @MainActor
    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lock.unlock()

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let loop = CFRunLoopGetCurrent()
            // A source that never fires, so the run loop has something to wait on while no app
            // is being watched.
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(loop, keepAlive, .defaultMode)
            self.lock.lock()
            self.runLoop = loop
            self.lock.unlock()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "dev.worklens.focus-changes"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
        ready.wait()

        // `queue: nil` runs the block on the posting thread, the main one, without a hop.
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.activated(pid: app?.processIdentifier)
        }
        scheduleInstall()
    }

    @MainActor
    public func stop() {
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        lock.lock()
        let loop = runLoop
        started = false
        runLoop = nil
        watchedPID = nil
        lock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            tearDown()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(loop)
    }

    public func mark() -> FocusChangeMark? {
        let trusted = AccessibilityPermission.isTrusted
        lock.lock()
        guard started else { lock.unlock(); return nil }
        let reach: FocusChangeMark.Reach
        var retry = false
        if !trusted {
            reach = .activationsOnly
        } else if let watchedPID, watchedPID == frontPID {
            reach = .full
        } else {
            reach = .blind
            // Accessibility granted since the last switch, or an app that was not ready to be
            // watched: try again, so one refusal does not cost every frame until the next switch.
            retry = !installPending
        }
        let result = FocusChangeMark(generation: generation, pid: frontPID, reach: reach)
        lock.unlock()
        if retry { scheduleInstall() }
        return result
    }

    // MARK: Counting

    private func activated(pid: pid_t?) {
        lock.lock()
        generation &+= 1
        frontPID = pid
        watchedPID = nil
        lock.unlock()
        scheduleInstall()
    }

    private func heard(_ notification: String) {
        lock.lock()
        generation &+= 1
        lock.unlock()
        if notification == kAXFocusedWindowChangedNotification
            || notification == kAXMainWindowChangedNotification
            || notification == kAXUIElementDestroyedNotification {
            watchFocusedWindow()
        }
    }

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<FocusChangeMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.heard(notification as String)
    }

    // MARK: The observer thread

    private func scheduleInstall() {
        lock.lock()
        guard started, let loop = runLoop else { lock.unlock(); return }
        installPending = true
        lock.unlock()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.installForFrontApp()
        }
        CFRunLoopWakeUp(loop)
    }

    /// On the observer thread: watch whatever is in front now.
    private func installForFrontApp() {
        lock.lock()
        let pid = frontPID
        lock.unlock()

        tearDown()
        var watching = false
        if let pid, AccessibilityPermission.isTrusted { watching = install(pid: pid) }

        lock.lock()
        installPending = false
        // A switch that landed while this ran has already queued its own install; until that one
        // finishes the newer app is not watched, and its marks say so.
        if watching, frontPID == pid { watchedPID = pid }
        lock.unlock()
    }

    private func install(pid: pid_t) -> Bool {
        var created: AXObserver?
        guard AXObserverCreate(pid, FocusChangeMonitor.callback, &created) == .success,
              let observer = created
        else { return false }
        let app = AXUIElementCreateApplication(pid)
        // A hung app costs this thread half a second per call, never the main actor.
        AXUIElementSetMessagingTimeout(app, 0.5)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var essential = false
        for name in FocusChangeMonitor.appNotifications {
            let error = AXObserverAddNotification(observer, app, name as CFString, refcon)
            if error == .success, FocusChangeMonitor.essentialNotifications.contains(name) {
                essential = true
            }
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
        appElement = app
        watchFocusedWindow()
        return essential
    }

    private func watchFocusedWindow() {
        guard let observer, let appElement else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let windowElement {
            for name in FocusChangeMonitor.windowNotifications {
                AXObserverRemoveNotification(observer, windowElement, name as CFString)
            }
            self.windowElement = nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
                == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return }
        let window = value as! AXUIElement   // swiftlint:disable:this force_cast
        for name in FocusChangeMonitor.windowNotifications {
            AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
        windowElement = window
    }

    private func tearDown() {
        guard let observer else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode
        )
        self.observer = nil
        appElement = nil
        windowElement = nil
    }
}
