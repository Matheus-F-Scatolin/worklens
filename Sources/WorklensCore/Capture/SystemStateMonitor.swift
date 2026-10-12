import AppKit
import CoreGraphics
import Foundation
import IOKit.ps

/// What one observer wants to hear about. Every callback is optional.
///
/// `onLock` and `onSleep` were added by #46: `ForegroundSessionRecorder` has to close its open
/// interval the moment the screen locks or the machine sleeps, and registering a second set of
/// `DistributedNotificationCenter` / `NSWorkspace` observers for the same notifications would be
/// two sources of truth for one fact.
@MainActor
public struct SystemStateHandlers {
    /// The machine woke or the screen unlocked.
    public var onWake: (() -> Void)?
    /// The screen locked, or the displays went to sleep — same thing as far as Worklens is
    /// concerned, since neither can be photographed honestly.
    public var onLock: (() -> Void)?
    public var onSleep: (() -> Void)?
    /// The charger went in or out, or Low Power Mode was switched (#145). Fires only when
    /// `power` actually changed value.
    public var onPowerChange: (() -> Void)?

    public init(
        onWake: (() -> Void)? = nil,
        onLock: (() -> Void)? = nil,
        onSleep: (() -> Void)? = nil,
        onPowerChange: (() -> Void)? = nil
    ) {
        self.onWake = onWake
        self.onLock = onLock
        self.onSleep = onSleep
        self.onPowerChange = onPowerChange
    }
}

/// The three OS facts the scheduler needs before deciding to capture: is the screen locked, is the
/// machine asleep, and how long since the user last touched anything.
///
/// A protocol because the scheduler's tests must be able to lock, sleep and idle the machine
/// without a machine.
///
/// **More than one observer may register.** The capture scheduler and the foreground session
/// recorder share one instance; `start(owner:handlers:)` adds a handler set keyed by `owner` and
/// installs the OS observers once, and `stop(owner:)` removes only that owner's — so stopping
/// capture does not silently deafen the recorder.
@MainActor
public protocol SystemStateProviding: AnyObject {
    var isLocked: Bool { get }
    var isAsleep: Bool { get }
    /// The charger and Low Power Mode, for `PowerPolicy` (#145). Defaulted below to `.mains` so a
    /// fake that does not care about batteries does not have to say so.
    var power: PowerState { get }
    /// Seconds since the last keyboard/mouse/tablet event, across the whole session.
    func idleSeconds() -> TimeInterval
    func start(owner: AnyObject, handlers: SystemStateHandlers)
    func stop(owner: AnyObject)
}

public extension SystemStateProviding {
    /// A Mac on mains, which is what every test that predates #145 is describing.
    var power: PowerState { .mains }

    /// The common case: only "we woke up" matters, so the scheduler can take a fresh frame
    /// instead of waiting out the rest of its interval.
    func start(owner: AnyObject, onWake: @escaping () -> Void) {
        start(owner: owner, handlers: SystemStateHandlers(onWake: onWake))
    }
}

/// The live implementation, over `DistributedNotificationCenter` (lock) and `NSWorkspace` (sleep).
@MainActor
public final class SystemStateMonitor: SystemStateProviding {
    /// The lock notifications only describe *transitions*, so a process that starts while the
    /// screen is already locked would never hear about it and would happily photograph the lock
    /// screen. The session dictionary is the authoritative answer and is cheap enough to read
    /// every tick; the observed flag adds the screens-asleep case it does not cover.
    public var isLocked: Bool { observedLocked || SystemStateMonitor.sessionScreenIsLocked() }
    public private(set) var isAsleep = false

    /// Read once at construction and then only when something says it changed (#145): the AC
    /// answer is an IOKit snapshot, which is not something to build on every tick.
    public private(set) var power: PowerState = SystemStateMonitor.readPower()

    private var observedLocked = false

    /// `CGSSessionScreenIsLocked` is absent rather than false when the screen is unlocked.
    static func sessionScreenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = session["CGSSessionScreenIsLocked"] as? Int { return locked != 0 }
        return false
    }

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    /// The IOKit run-loop source that reports the charger going in or out. There is no
    /// `NSWorkspace` notification for it, and polling a laptop's power source on a timer is the
    /// sort of thing this issue exists to stop doing.
    private var powerSourceRunLoopSource: CFRunLoopSource?
    /// Handler sets by owner, in registration order.
    private var handlers: [(owner: ObjectIdentifier, handlers: SystemStateHandlers)] = []

    public init() {}

    public func idleSeconds() -> TimeInterval {
        // `CGEventType(rawValue: ~0)` is the documented "any event type" wildcard; combined with
        // `.combinedSessionState` it reports idle time across the whole login session, not just
        // events this process saw.
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    public func start(owner: AnyObject, handlers newHandlers: SystemStateHandlers) {
        let id = ObjectIdentifier(owner)
        handlers.removeAll { $0.owner == id }
        handlers.append((id, newHandlers))
        guard observers.isEmpty, distributedObservers.isEmpty else { return }

        let distributed = DistributedNotificationCenter.default()
        distributedObservers = [
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.setLocked(true) }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.setLocked(false) }
            },
        ]

        let workspace = NSWorkspace.shared.notificationCenter
        // Screens sleeping is treated exactly like a lock: the display is off, so a screenshot
        // would be either black or a lie about what you were doing.
        let mapping: [(Notification.Name, (SystemStateMonitor) -> () -> Void)] = [
            (NSWorkspace.willSleepNotification, { monitor in { monitor.setAsleep(true) } }),
            (NSWorkspace.didWakeNotification, { monitor in { monitor.setAsleep(false) } }),
            (NSWorkspace.screensDidSleepNotification, { monitor in { monitor.setLocked(true) } }),
            (NSWorkspace.screensDidWakeNotification, { monitor in { monitor.setLocked(false) } }),
        ]
        for (name, action) in mapping {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)()
                }
            }
            observers.append((workspace, token))
        }

        // #145: Low Power Mode is a Foundation notification; the charger is not one at all, so
        // it takes an IOKit run-loop source. Both land in the same `refreshPower()`.
        let center = NotificationCenter.default
        let powerToken = center.addObserver(
            // `NSProcessInfoPowerStateDidChange` is what the Foundation constant is called on
            // macOS; `ProcessInfo.processInfoPowerStateDidChangeNotification` is the iOS spelling
            // and does not exist here.
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPower() }
        }
        observers.append((center, powerToken))
        startObservingPowerSource()
    }

    public func stop(owner: AnyObject) {
        handlers.removeAll { $0.owner == ObjectIdentifier(owner) }
        guard handlers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.forEach(distributed.removeObserver)
        distributedObservers = []
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
    }

    // MARK: Power (#145)

    /// The run-loop source below holds an unretained pointer back here, so it must not outlive
    /// the monitor. `stop(owner:)` is the normal path; this is the one where nobody called it.
    deinit {
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private func startObservingPowerSource() {
        guard powerSourceRunLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let monitor = Unmanaged<SystemStateMonitor>.fromOpaque(context).takeUnretainedValue()
                // The source is on the main run loop, so this callback is already on the main
                // thread; `assumeIsolated` is the compiler being told so.
                MainActor.assumeIsolated { monitor.refreshPower() }
            }, context)?.takeRetainedValue()
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceRunLoopSource = source
    }

    /// Re-reads both power facts and tells the handlers only when something actually moved — the
    /// power-source source fires for battery percentage too, which is none of Worklens's business.
    private func refreshPower() {
        let fresh = SystemStateMonitor.readPower()
        guard fresh != power else { return }
        power = fresh
        notify(\.onPowerChange)
    }

    /// `IOPSGetProvidingPowerSourceType` over a fresh snapshot, plus Low Power Mode. A Mac with
    /// no battery at all answers "AC Power", which is the right answer for a desktop.
    static func readPower() -> PowerState {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerState(onBattery: false, lowPowerMode: lowPower)
        }
        let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        return PowerState(
            onBattery: source == kIOPMBatteryPowerKey || source == kIOPMUPSPowerKey,
            lowPowerMode: lowPower
        )
    }

    private func setLocked(_ locked: Bool) {
        guard locked != observedLocked else { return }
        observedLocked = locked
        locked ? notify(\.onLock) : notify(\.onWake)
    }

    private func setAsleep(_ asleep: Bool) {
        guard asleep != isAsleep else { return }
        isAsleep = asleep
        asleep ? notify(\.onSleep) : notify(\.onWake)
    }

    /// Iterated over a copy: a handler is free to register or unregister while it runs.
    private func notify(_ callback: KeyPath<SystemStateHandlers, (() -> Void)?>) {
        for entry in handlers { entry.handlers[keyPath: callback]?() }
    }
}
