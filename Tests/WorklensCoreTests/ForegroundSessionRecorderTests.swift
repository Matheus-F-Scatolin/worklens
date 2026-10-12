import Foundation
import Testing
@testable import WorklensCore

// MARK: - Fakes

/// A clock whose sleep never returns on its own. The recorder's idle poll is driven by calling
/// `pollIdle()` directly, so the loop must not spin while a test runs.
private struct NeverClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await Task.sleep(for: .seconds(86_400))
    }
}

/// Wall time the test moves by hand.
private final class FakeClockDate: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); current += seconds; lock.unlock()
    }
}

@MainActor
private final class FakeSystem: SystemStateProviding {
    var isLocked = false
    var isAsleep = false
    var idle: TimeInterval = 0

    private var handlers: [(owner: ObjectIdentifier, handlers: SystemStateHandlers)] = []
    var observerCount: Int { handlers.count }

    func idleSeconds() -> TimeInterval { idle }

    func start(owner: AnyObject, handlers newHandlers: SystemStateHandlers) {
        let id = ObjectIdentifier(owner)
        handlers.removeAll { $0.owner == id }
        handlers.append((id, newHandlers))
    }

    func stop(owner: AnyObject) {
        handlers.removeAll { $0.owner == ObjectIdentifier(owner) }
    }

    func lock() { isLocked = true; notify(\.onLock) }
    func sleep() { isAsleep = true; notify(\.onSleep) }
    func wake() { isLocked = false; isAsleep = false; notify(\.onWake) }

    private func notify(_ callback: KeyPath<SystemStateHandlers, (() -> Void)?>) {
        for entry in handlers { entry.handlers[keyPath: callback]?() }
    }
}

@MainActor
private final class FakeActivation: AppActivationObserving {
    var front: ActivatedApp?
    private var onActivate: ((ActivatedApp) -> Void)?
    private(set) var started = false

    init(front: ActivatedApp?) { self.front = front }

    func frontmostApp() -> ActivatedApp? { front }

    func start(onActivate: @escaping (ActivatedApp) -> Void) {
        self.onActivate = onActivate
        started = true
    }

    func stop() {
        onActivate = nil
        started = false
    }

    /// A foreground switch, as `NSWorkspace.didActivateApplicationNotification` would report it.
    func activate(_ app: ActivatedApp) {
        front = app
        onActivate?(app)
    }
}

// MARK: - Harness

private let xcode = ActivatedApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")
private let slack = ActivatedApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
private let bank = ActivatedApp(bundleID: "com.bank.Vault", name: "Vault")
private let start = Date(timeIntervalSince1970: 1_757_260_800)

@MainActor
private struct Harness {
    let recorder: ForegroundSessionRecorder
    let store: ForegroundSessionStore
    let db: Database
    let system: FakeSystem
    let activation: FakeActivation
    let clock: FakeClockDate

    init(front: ActivatedApp? = xcode, configure: (inout Config) -> Void = { _ in }) throws {
        var config = Config.defaults()
        configure(&config)
        db = try Database.inMemory()
        store = ForegroundSessionStore(db)
        system = FakeSystem()
        activation = FakeActivation(front: front)
        clock = FakeClockDate(start)

        let clock = self.clock
        recorder = ForegroundSessionRecorder(
            config: config,
            db: db,
            activation: activation,
            system: system,
            clock: NeverClock(),
            now: { clock.now }
        )
    }

    /// Every row, oldest first.
    func rows() throws -> [ForegroundSession] {
        try store.fetch(overlapping: .distantPast, to: .distantFuture)
    }
}

/// Seconds since the fixed start, so an assertion reads as "40 seconds in".
private func offset(_ date: Date?) -> TimeInterval? {
    date.map { $0.timeIntervalSince(start) }
}

// MARK: - Tests

@Suite("ForegroundSessionRecorder")
@MainActor
struct ForegroundSessionRecorderTests {
    @Test("a switch closes the open interval and opens the next at the same instant")
    func switchClosesAndOpens() throws {
        let harness = try Harness()
        harness.recorder.start()

        harness.clock.advance(40)
        harness.activation.activate(slack)

        let rows = try harness.rows()
        #expect(rows.count == 2)
        #expect(rows[0].appBundleId == xcode.bundleID)
        #expect(offset(rows[0].startAt) == 0)
        #expect(offset(rows[0].endAt) == 40)
        #expect(rows[1].appBundleId == slack.bundleID)
        #expect(offset(rows[1].startAt) == 40)
        #expect(rows[1].isOpen)
    }

    @Test("a forty-second detour between two ticks is a forty-second row")
    func shortDetourIsRecorded() throws {
        let harness = try Harness()
        harness.recorder.start()

        harness.clock.advance(20)
        harness.activation.activate(slack)
        harness.clock.advance(40)
        harness.activation.activate(xcode)

        let rows = try harness.rows()
        #expect(rows.count == 3)
        #expect(rows[1].appBundleId == slack.bundleID)
        #expect(rows[1].seconds == 40)
    }

    @Test("an activation for the app already in front does not split the interval")
    func repeatedActivationIsIgnored() throws {
        let harness = try Harness()
        harness.recorder.start()

        harness.clock.advance(30)
        harness.activation.activate(xcode)

        let rows = try harness.rows()
        #expect(rows.count == 1)
        #expect(rows[0].isOpen)
    }

    @Test("lock closes the open interval and wake reopens it, without waiting for a tick")
    func lockAndWake() throws {
        let harness = try Harness()
        harness.recorder.start()

        harness.clock.advance(60)
        harness.system.lock()
        #expect(try harness.rows().allSatisfy { !$0.isOpen })

        harness.clock.advance(300)
        harness.system.wake()

        let rows = try harness.rows()
        #expect(rows.count == 2)
        #expect(offset(rows[0].endAt) == 60)
        #expect(offset(rows[1].startAt) == 360)
        #expect(rows[1].isOpen)
    }

    @Test("sleep closes the open interval too")
    func sleepCloses() throws {
        let harness = try Harness()
        harness.recorder.start()

        harness.clock.advance(120)
        harness.system.sleep()

        let rows = try harness.rows()
        #expect(rows.count == 1)
        #expect(offset(rows[0].endAt) == 120)
    }

    @Test("pause records nothing at all, and closes what was open")
    func pauseRecordsNothing() throws {
        let harness = try Harness()
        harness.recorder.start()

        harness.clock.advance(60)
        harness.recorder.pause()
        harness.clock.advance(60)
        harness.activation.activate(slack)
        harness.clock.advance(60)
        harness.system.wake()

        let rows = try harness.rows()
        #expect(rows.count == 1)
        #expect(offset(rows[0].endAt) == 60)

        harness.recorder.resume()
        let after = try harness.rows()
        #expect(after.count == 2)
        #expect(after[1].appBundleId == slack.bundleID)
        #expect(offset(after[1].startAt) == 180)
    }

    @Test("idle closes the interval at the last input, not at the moment the poll noticed")
    func idleClosesAtLastInput() throws {
        let harness = try Harness { $0.captureIdleSeconds = 120 }
        harness.recorder.start()

        // Twelve minutes later the user has been away for ten of them.
        harness.clock.advance(720)
        harness.system.idle = 600
        harness.recorder.pollIdle()

        let rows = try harness.rows()
        #expect(rows.count == 1)
        #expect(offset(rows[0].endAt) == 120)
    }

    @Test("the first input after an idle stretch reopens the interval")
    func firstInputReopens() throws {
        let harness = try Harness { $0.captureIdleSeconds = 120 }
        harness.recorder.start()

        harness.clock.advance(720)
        harness.system.idle = 600
        harness.recorder.pollIdle()

        // Next poll: the user typed five seconds ago.
        harness.clock.advance(30)
        harness.system.idle = 5
        harness.recorder.pollIdle()

        let rows = try harness.rows()
        #expect(rows.count == 2)
        #expect(offset(rows[1].startAt) == 745)
        #expect(rows[1].isOpen)
    }

    @Test("a reopen can never reach back before the close it follows")
    func reopenIsFlooredAtTheClose() throws {
        let harness = try Harness { $0.captureIdleSeconds = 120 }
        harness.recorder.start()

        harness.clock.advance(300)
        harness.system.idle = 200
        harness.recorder.pollIdle()
        #expect(offset(try harness.rows()[0].endAt) == 100)

        // A poll one second later reporting a 300 s idle time would otherwise open the new
        // interval before the old one ended.
        harness.clock.advance(1)
        harness.system.idle = 1
        harness.recorder.pollIdle()
        #expect(offset(try harness.rows()[1].startAt) == 300)
    }

    @Test("a blocked bundle keeps its interval and loses its name")
    func blockedBundleIsAnonymous() throws {
        let harness = try Harness(front: bank) {
            $0.blockedBundleIDs = ["com.bank.Vault"]
        }
        harness.recorder.start()
        harness.clock.advance(90)
        harness.activation.activate(xcode)

        let rows = try harness.rows()
        #expect(rows.count == 2)
        #expect(rows[0].isBlocked)
        #expect(rows[0].appBundleId == nil)
        #expect(rows[0].appName == nil)
        #expect(rows[0].seconds == 90)
        #expect(rows[1].appBundleId == xcode.bundleID)
    }

    @Test("a row left open by a kill is closed at the last evidence, not at relaunch")
    func staleRowClosedAtLastEvidence() throws {
        let harness = try Harness()
        // Yesterday's process left an interval open an hour ago; the newest frame is 30 min old.
        try harness.store.insert(ForegroundSession(
            startAt: start.addingTimeInterval(-3600), appBundleId: slack.bundleID, appName: "Slack"
        ))
        try CaptureStore(harness.db).insert(Capture(
            capturedAt: start.addingTimeInterval(-1800), appBundleId: slack.bundleID
        ))

        harness.recorder.start()

        let rows = try harness.rows()
        #expect(rows.count == 2)
        #expect(offset(rows[0].endAt) == -1800)
        #expect(offset(rows[1].startAt) == 0)
    }

    @Test("with no frames at all the stale row is closed at launch")
    func staleRowWithoutEvidence() throws {
        let harness = try Harness()
        try harness.store.insert(ForegroundSession(
            startAt: start.addingTimeInterval(-3600), appBundleId: slack.bundleID
        ))

        harness.recorder.start()
        #expect(offset(try harness.rows()[0].endAt) == 0)
    }

    @Test("stop closes the open interval and unregisters both observers")
    func stopCloses() throws {
        let harness = try Harness()
        harness.recorder.start()
        #expect(harness.system.observerCount == 1)
        #expect(harness.activation.started)

        harness.clock.advance(45)
        harness.recorder.stop()

        #expect(harness.system.observerCount == 0)
        #expect(!harness.activation.started)
        #expect(offset(try harness.rows()[0].endAt) == 45)
    }

    @Test("nothing opens while the screen is locked")
    func lockedStaysSilent() throws {
        let harness = try Harness()
        harness.system.isLocked = true
        harness.recorder.start()
        #expect(try harness.rows().isEmpty)
    }

    @Test("at most one row is ever open")
    func oneOpenRowAtATime() throws {
        let harness = try Harness()
        harness.recorder.start()
        for step in 1...5 {
            harness.clock.advance(10)
            harness.activation.activate(step.isMultiple(of: 2) ? xcode : slack)
        }
        #expect(try harness.rows().filter(\.isOpen).count == 1)
    }
}
