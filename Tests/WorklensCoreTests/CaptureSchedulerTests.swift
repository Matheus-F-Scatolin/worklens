import CoreGraphics
import Foundation
import Testing
@testable import WorklensCore

// MARK: - Fakes

/// A clock the scheduler can sleep on without any wall time passing. The scheduler's own loop is
/// never started in these tests — ticks are driven directly — so `sleep` only has to return.
private struct InstantClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {}
}

/// A clock whose sleeps never return on their own, for the handful of tests that start the real
/// loop: it parks on the first sleep, so every tick is still one the test asked for. `stop()`
/// cancels it.
private struct ParkedClock: Clock {
    typealias Instant = InstantClock.Instant

    var now: Instant { Instant() }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

/// Wall time the test controls, so heartbeats and pause deadlines are arithmetic, not waiting.
private final class FakeClockDate: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_757_260_800)) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); current += seconds; lock.unlock()
    }
}

@MainActor
private final class FakeSystemState: SystemStateProviding {
    var isLocked = false
    var isAsleep = false
    var idle: TimeInterval = 0
    /// #145: the charger, driven by hand. The live monitor reads IOKit; nothing here does.
    var power: PowerState = .mains
    var started: Bool { !handlers.isEmpty }

    private var handlers: [(owner: ObjectIdentifier, handlers: SystemStateHandlers)] = []

    func idleSeconds() -> TimeInterval { idle }

    func start(owner: AnyObject, handlers newHandlers: SystemStateHandlers) {
        let id = ObjectIdentifier(owner)
        handlers.removeAll { $0.owner == id }
        handlers.append((id, newHandlers))
    }

    func stop(owner: AnyObject) {
        handlers.removeAll { $0.owner == ObjectIdentifier(owner) }
    }

    /// The three transitions #46 added, driven by hand.
    func lock() { isLocked = true; notify(\.onLock) }
    func sleep() { isAsleep = true; notify(\.onSleep) }
    func wake() { isLocked = false; isAsleep = false; notify(\.onWake) }
    /// #145: the charger going in or out, or Low Power Mode being switched.
    func setPower(_ fresh: PowerState) { power = fresh; notify(\.onPowerChange) }

    private func notify(_ callback: KeyPath<SystemStateHandlers, (() -> Void)?>) {
        for entry in handlers { entry.handlers[keyPath: callback]?() }
    }
}

private final class FakeContext: ForegroundContextProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ForegroundContext

    init(_ value: ForegroundContext) { self.value = value }

    var current: ForegroundContext {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }

    func collect() -> ForegroundContext { current }
}

/// Hands back solid-gray frames: two calls with the same gray look identical to `changeScore`,
/// two with different grays look completely different.
private final class FakeCapture: ScreenCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var gray: Double
    private var permission: PermissionState
    private(set) var captureCount = 0

    init(gray: Double = 0.5, permission: PermissionState = .granted) {
        self.gray = gray
        self.permission = permission
    }

    func setGray(_ value: Double) { lock.lock(); gray = value; lock.unlock() }
    func setPermission(_ value: PermissionState) { lock.lock(); permission = value; lock.unlock() }

    func permissionState() async -> PermissionState {
        lock.lock(); defer { lock.unlock() }
        return permission
    }

    func capture() async throws -> CapturedFrame {
        lock.lock()
        let value = gray
        let denied = permission == .denied
        captureCount += 1
        lock.unlock()
        if denied { throw CaptureError.permissionDenied }

        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: value, green: value, blue: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return CapturedFrame(
            image: context.makeImage()!, displayID: 1,
            pointSize: CGSize(width: 64, height: 64), capturedAt: Date()
        )
    }
}

/// A snapshotter that hands back whatever the test asked for, and records what was asked of it.
/// `snapshot` is what #53 wires into the tick; `resetEnhancedUserInterface` is the switch the
/// scheduler has to turn back off when the frontmost app changes.
private final class FakeSnapshotter: AccessibilitySnapshotting, @unchecked Sendable {
    private let lock = NSLock()
    private var next: AXSnapshot?
    private(set) var pids: [pid_t] = []
    private(set) var resetPids: [pid_t] = []

    init(_ snapshot: AXSnapshot?) { next = snapshot }

    /// Builds a snapshot whose coverage is exactly what the test names, so the decision rules can
    /// be driven without a real accessibility tree.
    static func snapshot(
        coverage: AXSnapshot.Coverage,
        text: String,
        nodes: Int = 40,
        elapsedMs: Int = 40,
        documentURL: String? = nil,
        setEnhanced: Bool = false
    ) -> AXSnapshot {
        AXSnapshot(
            documentURL: documentURL,
            nodes: (0..<nodes).map { _ in AXNode(role: "AXStaticText", depth: 1) },
            text: text,
            textHash: AXOutline.hash(text),
            coverage: coverage,
            elapsedMs: elapsedMs,
            didSetEnhancedUserInterface: setEnhanced
        )
    }

    func set(_ snapshot: AXSnapshot?) { lock.lock(); next = snapshot; lock.unlock() }

    /// Same coverage and node count, new text — one window whose content moved.
    func setText(_ text: String) {
        lock.lock()
        if var snapshot = next {
            snapshot.text = text
            snapshot.textHash = AXOutline.hash(text)
            next = snapshot
        }
        lock.unlock()
    }

    func snapshot(pid: pid_t) async -> AXSnapshot? {
        lock.lock(); defer { lock.unlock() }
        pids.append(pid)
        return next
    }

    func resetEnhancedUserInterface(pid: pid_t) async {
        lock.lock(); resetPids.append(pid); lock.unlock()
    }
}

// MARK: - Harness

@MainActor
private struct Harness {
    let scheduler: CaptureScheduler
    /// Exposed so #19's calendar-driven meeting detection can be driven from a test.
    let meeting: MeetingDetector
    let db: Database
    let store: CaptureStore
    let system: FakeSystemState
    let context: FakeContext
    let capture: FakeCapture
    let clock: FakeClockDate
    let dataDir: URL
    let snapshotter: FakeSnapshotter?

    init(
        configure: (inout Config) -> Void = { _ in },
        // A second harness over the first one's database and clock is what "the app was quit and
        // launched again" looks like from a test (#113).
        reusing existingDB: Database? = nil,
        clock existingClock: FakeClockDate? = nil,
        /// Start the real loop rather than driving ticks only: it parks on its first sleep.
        parkedLoop: Bool = false,
        capture: FakeCapture = FakeCapture(),
        context: ForegroundContext = ForegroundContext(
            bundleID: "com.apple.Terminal", appName: "Terminal", pid: 1, windowTitle: "zsh"
        ),
        costGate: any CostGate = AlwaysAllowCostGate(),
        snapshotter: FakeSnapshotter? = nil
    ) throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-tests-\(UUID().uuidString)")
        var config = Config.defaults()
        config.dataDir = dataDir
        config.collectBrowserURL = false
        configure(&config)

        db = try existingDB ?? Database.inMemory()
        store = CaptureStore(db)
        system = FakeSystemState()
        self.context = FakeContext(context)
        self.capture = capture
        clock = existingClock ?? FakeClockDate()
        self.snapshotter = snapshotter

        let clock = self.clock
        meeting = MeetingDetector(now: { clock.now })
        scheduler = CaptureScheduler(
            config: config,
            db: db,
            capture: capture,
            context: self.context,
            meeting: meeting,
            system: system,
            costGate: costGate,
            snapshotter: snapshotter,
            clock: parkedLoop ? ParkedClock() : InstantClock(),
            now: { clock.now }
        )
    }

    func axRows() throws -> [AXSnapshotRecord] {
        try db.writer.read { try AXSnapshotRecord.fetchAll($0) }
    }

    func axRow(_ captureId: String) throws -> AXSnapshotRecord? {
        try AXSnapshotStore(db).fetch(captureId: captureId)
    }

    func storedAXHash() throws -> String? {
        try store.fetchLastAXTextHash()
    }

    /// Every `.jpg` under the data dir — what "no picture was taken" has to mean on disk.
    func jpegCount() throws -> Int {
        let enumerator = FileManager.default.enumerator(at: dataDir, includingPropertiesForKeys: nil)
        var count = 0
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "jpg" { count += 1 }
        }
        return count
    }

    func rows() throws -> [Capture] {
        try db.writer.read { try Capture.fetchAll($0) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: dataDir)
    }
}

// MARK: - The describe decision

@Suite("needsDescribe")
struct DescribeDecisionTests {
    private func decide(
        score: Double?, changed: Bool = false, since: TimeInterval? = 10,
        threshold: Double = 0.03, heartbeat: TimeInterval = 300
    ) -> Bool {
        DescribeDecision.needsDescribe(
            changeScore: score, signatureChanged: changed,
            secondsSinceLastDescribed: since, threshold: threshold, heartbeat: heartbeat
        )
    }

    @Test("The first frame is always described — there is nothing to compare it to")
    func firstFrame() {
        #expect(decide(score: nil) == true)
        #expect(decide(score: nil, since: nil) == true)
    }

    @Test("An app or page switch beats a still screen")
    func signatureChange() {
        #expect(decide(score: 0.0, changed: true) == true)
    }

    @Test("The threshold is inclusive at the boundary")
    func thresholdBoundary() {
        #expect(decide(score: 0.0299) == false)
        #expect(decide(score: 0.03) == true)
        #expect(decide(score: 0.031) == true)
    }

    @Test("The heartbeat rescues a screen that has not moved in five minutes")
    func heartbeat() {
        #expect(decide(score: 0.001, since: 299) == false)
        #expect(decide(score: 0.001, since: 300) == true)
        #expect(decide(score: 0.001, since: nil) == true)
    }

    @Test("A zero threshold describes everything, a threshold of 1 leans on the heartbeat")
    func extremeThresholds() {
        #expect(decide(score: 0.0, threshold: 0) == true)
        #expect(decide(score: 0.99, since: 10, threshold: 1.0) == false)
        #expect(decide(score: 0.99, since: 400, threshold: 1.0) == true)
    }
}

// MARK: - The decision with a text hash (#53)

@Suite("needsDescribe with window text")
struct DescribeDecisionTextTests {
    private func decide(
        score: Double?, changed: Bool = false, since: TimeInterval? = 10,
        threshold: Double = 0.03, heartbeat: TimeInterval = 300,
        textChanged: Bool?, coverage: AXSnapshot.Coverage?
    ) -> Bool {
        DescribeDecision.needsDescribe(
            changeScore: score, signatureChanged: changed,
            secondsSinceLastDescribed: since, threshold: threshold, heartbeat: heartbeat,
            textChanged: textChanged, coverage: coverage
        )
    }

    @Test("A full frame whose text moved is described, however still the pixels are")
    func fullTextChanged() {
        #expect(decide(score: 0.0, textChanged: true, coverage: .full) == true)
    }

    @Test("A full frame with unmoved text ignores the pixels — this is the video-frame saving")
    func fullTextUnchangedIgnoresPixels() {
        // 0.9 is a completely different screen by the pixel rule; the window text says otherwise.
        #expect(decide(score: 0.9, textChanged: false, coverage: .full) == false)
        #expect(decide(score: 0.0, textChanged: false, coverage: .full) == false)
    }

    @Test("A full frame still yields to a window switch and to the heartbeat")
    func fullKeepsSignatureAndHeartbeat() {
        #expect(decide(score: 0.9, changed: true, textChanged: false, coverage: .full) == true)
        #expect(decide(score: 0.0, since: 299, textChanged: false, coverage: .full) == false)
        #expect(decide(score: 0.0, since: 300, textChanged: false, coverage: .full) == true)
        #expect(decide(score: 0.0, since: nil, textChanged: false, coverage: .full) == true)
    }

    @Test("A partial frame keeps the pixel rule and only ever adds to it")
    func partialAddsToPixels() {
        // Text moved, pixels did not: described, which today's rule would have missed.
        #expect(decide(score: 0.0, textChanged: true, coverage: .partial) == true)
        // Pixels moved, text did not: still described — a partial tree is not evidence of calm.
        #expect(decide(score: 0.9, textChanged: false, coverage: .partial) == true)
        #expect(decide(score: 0.0, textChanged: false, coverage: .partial) == false)
    }

    @Test("No snapshot, or a snapshot that found nothing, leaves today's rule alone")
    func noOpinionFallsBack() {
        #expect(decide(score: 0.9, textChanged: nil, coverage: nil) == true)
        #expect(decide(score: 0.0, textChanged: nil, coverage: nil) == false)
        // `.none` never consults the hash, even if one was somehow computed.
        #expect(decide(score: 0.9, textChanged: false, coverage: AXSnapshot.Coverage.none) == true)
        #expect(decide(score: 0.0, textChanged: true, coverage: AXSnapshot.Coverage.none) == false)
    }

    @Test("The very first frame is described whatever the text says")
    func firstFrameWins() {
        #expect(decide(score: nil, textChanged: false, coverage: .full) == true)
    }

    @Test("With no pixels at all, the text hash, the signature and the heartbeat are the rule")
    func textOnlyDecision() {
        func decide(
            textChanged: Bool, signatureChanged: Bool = false, since: TimeInterval? = 10
        ) -> Bool {
            DescribeDecision.needsDescribeFromText(
                textChanged: textChanged, signatureChanged: signatureChanged,
                secondsSinceLastDescribed: since, heartbeat: 300
            )
        }
        #expect(decide(textChanged: true))
        #expect(decide(textChanged: false) == false)
        // A new window in the same app, with an outline that happens to hash the same.
        #expect(decide(textChanged: false, signatureChanged: true))
        // The heartbeat still fires, and nothing described yet counts as due.
        #expect(decide(textChanged: false, since: 400))
        #expect(decide(textChanged: false, since: nil))
        // Deliberately the same three terms as the `.full` branch of `needsDescribe`.
        #expect(decide(textChanged: false, since: 10) == DescribeDecision.needsDescribe(
            changeScore: 0.9, signatureChanged: false, secondsSinceLastDescribed: 10,
            threshold: 0.03, heartbeat: 300, textChanged: false, coverage: .full
        ))
    }

    @Test("A thin tree that graded full is demoted, so the pixel rule survives it")
    func thinFullIsDemoted() {
        // #52 measured Slack at two nodes and 130 characters, graded `.full`.
        #expect(DescribeDecision.trustedCoverage(.full, nodeCount: 2) == .partial)
        #expect(DescribeDecision.trustedCoverage(.full, nodeCount: 40) == .full)
        #expect(DescribeDecision.trustedCoverage(.partial, nodeCount: 400) == .partial)
        #expect(
            DescribeDecision.trustedCoverage(AXSnapshot.Coverage.none, nodeCount: 0)
                == AXSnapshot.Coverage.none
        )
        #expect(
            DescribeDecision.trustedCoverage(.full, nodeCount: DescribeDecision.trustedFullMinNodes)
                == .full
        )
    }
}

// MARK: - Meeting detection

@Suite("MeetingDetector")
struct MeetingDetectorTests {
    @Test("Meeting apps")
    func apps() {
        #expect(MeetingDetector.detects(bundleID: "us.zoom.xos", urlHost: nil, windowTitle: nil))
        #expect(MeetingDetector.detects(bundleID: "com.microsoft.teams2", urlHost: nil, windowTitle: nil))
        #expect(!MeetingDetector.detects(bundleID: "com.apple.Terminal", urlHost: nil, windowTitle: nil))
    }

    @Test("Meeting hosts, including a company's own Zoom subdomain")
    func hosts() {
        #expect(MeetingDetector.detects(bundleID: "com.google.Chrome", urlHost: "meet.google.com", windowTitle: nil))
        #expect(MeetingDetector.detects(bundleID: "com.google.Chrome", urlHost: "acme.zoom.us", windowTitle: nil))
        #expect(!MeetingDetector.detects(bundleID: "com.google.Chrome", urlHost: "notzoom.us", windowTitle: nil))
        #expect(!MeetingDetector.detects(bundleID: "com.google.Chrome", urlHost: "news.ycombinator.com", windowTitle: nil))
    }

    @Test("A Slack huddle counts; ordinary Slack does not")
    func slackHuddle() {
        #expect(MeetingDetector.detects(
            bundleID: "com.tinyspeck.slackmacgap", urlHost: nil, windowTitle: "Huddle with Ana"
        ))
        #expect(!MeetingDetector.detects(
            bundleID: "com.tinyspeck.slackmacgap", urlHost: nil, windowTitle: "#engineering"
        ))
        // The word only counts inside Slack: an article about huddles is not a meeting.
        #expect(!MeetingDetector.detects(
            bundleID: "com.google.Chrome", urlHost: "example.com", windowTitle: "The huddle problem"
        ))
    }

    // MARK: The browser title fallback (#64)

    private func detectsTitle(
        _ title: String?, bundleID: String? = "com.google.Chrome", host: String? = nil
    ) -> Bool {
        MeetingDetector.detects(bundleID: bundleID, urlHost: host, windowTitle: title)
    }

    @Test("#64: with no host at all, a Google Meet window title is enough")
    func meetTitleWithoutAHost() {
        #expect(detectsTitle("Meet - abc-defg-hij 🔊"))
        #expect(detectsTitle("Meet - abc-defg-hij"))
        // Firefox exposes no scriptable URL, so its title is the only signal it will ever give.
        #expect(detectsTitle("Meet - abc-defg-hij", bundleID: "org.mozilla.firefox"))
    }

    @Test("#64: the Zoom and Teams web clients are named the same way")
    func webClientTitles() {
        #expect(detectsTitle("Zoom Meeting"))
        #expect(detectsTitle("Microsoft Teams"))
        #expect(detectsTitle("microsoft teams"))
    }

    @Test("#64: anchored, so a page that merely mentions a call does not count")
    func titlesAreAnchored() {
        #expect(!detectsTitle("Meet the team - Google Docs"))
        #expect(!detectsTitle("Notes on Microsoft Teams rollout"))
        #expect(!detectsTitle("How to schedule a Zoom Meeting"))
        #expect(!detectsTitle(nil))
        #expect(!detectsTitle("   "))
    }

    @Test("#64: only for browsers, and only when there is no host to judge by")
    func titleFallbackIsNarrow() {
        // A non-browser window called "Meet - …" is a document about a meeting, not a meeting.
        #expect(!detectsTitle("Meet - abc-defg-hij", bundleID: "com.apple.Terminal"))
        // A host that *was* read decides on its own — a Docs page titled like a Meet window is
        // still a Docs page — and a real meeting host still wins.
        #expect(!detectsTitle("Meet - abc-defg-hij", host: "docs.google.com"))
        #expect(detectsTitle("Meet - abc-defg-hij", host: "meet.google.com"))
    }

    @MainActor
    @Test("update() flips the published flag")
    func updateFlips() {
        let detector = MeetingDetector()
        #expect(detector.isInMeeting == false)
        detector.update(context: ForegroundContext(bundleID: "us.zoom.xos"))
        #expect(detector.isInMeeting == true)
        detector.update(context: ForegroundContext(bundleID: "com.apple.Terminal"))
        #expect(detector.isInMeeting == false)
    }
}

// MARK: - Scheduler behaviour

@MainActor
@Suite("CaptureScheduler ticks")
struct CaptureSchedulerTests {
    @Test("A first tick captures, saves an image and queues it for describing")
    func firstTickSaves() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(result.decision == .describedPending)
        #expect(result.savedImage)

        let rows = try harness.rows()
        #expect(rows.count == 1)
        #expect(rows[0].imagePath != nil)
        #expect(rows[0].describeStatus == .pending)
        #expect(rows[0].appBundleId == "com.apple.Terminal")
        #expect(rows[0].dhash?.count == 16)

        let path = harness.dataDir.appendingPathComponent(rows[0].imagePath!)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("An identical screen writes a row with no image, marked for inheritance")
    func unchangedFrameStoresNoImage() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        harness.clock.advance(60)
        let second = await harness.scheduler.tick()

        #expect(second.decision == .unchanged)
        #expect(second.savedImage == false)

        let rows = try harness.rows()
        #expect(rows.count == 2)
        #expect(rows[1].imagePath == nil)
        #expect(rows[1].describeStatus == .inherited)
        #expect(rows[1].skipReason == .unchanged)
        // Only one JPEG on disk, for the first frame.
        let files = try FileManager.default.subpathsOfDirectory(atPath: harness.dataDir.path)
        #expect(files.filter { $0.hasSuffix(".jpg") }.count == 1)
    }

    @Test("A changed screen is described again")
    func changedFrameIsDescribed() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        harness.capture.setGray(0.9)
        harness.clock.advance(60)
        let second = await harness.scheduler.tick()

        #expect(second.decision == .describedPending)
        #expect((second.changeScore ?? 0) > 0.03)
    }

    @Test("The heartbeat describes a motionless screen every CAPTURE_HEARTBEAT_SECONDS")
    func heartbeatFires() async throws {
        let harness = try Harness { $0.captureHeartbeatSeconds = 300 }
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        harness.clock.advance(60)
        #expect(await harness.scheduler.tick().decision == .unchanged)

        harness.clock.advance(300)
        #expect(await harness.scheduler.tick().decision == .describedPending)
    }

    @Test("An app switch alone forces a describe, even with a pixel-identical screen")
    func signatureChangeForcesDescribe() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        harness.clock.advance(60)
        harness.context.current = ForegroundContext(
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", pid: 2, windowTitle: "#eng"
        )
        let second = await harness.scheduler.tick()
        #expect(second.decision == .describedPending)
        #expect(second.changeScore == 0)   // the pixels never moved; the context did
    }

    // MARK: One row per period

    @Test("Locking writes exactly one row, however many ticks pass; unlocking resumes")
    func lockWritesOneRow() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.system.isLocked = true
        for _ in 0..<5 {
            #expect(await harness.scheduler.tick().decision == .locked)
            harness.clock.advance(60)
        }
        var rows = try harness.rows()
        #expect(rows.count == 1)
        #expect(rows[0].skipReason == .locked)
        #expect(rows[0].isIdle)
        #expect(rows[0].imagePath == nil)
        #expect(harness.capture.captureCount == 0)
        #expect(harness.scheduler.state == .locked)

        harness.system.isLocked = false
        #expect(await harness.scheduler.tick().decision == .describedPending)
        rows = try harness.rows()
        #expect(rows.count == 2)

        // A second lock period is a second row.
        harness.system.isLocked = true
        harness.clock.advance(60)
        _ = await harness.scheduler.tick()
        #expect(try harness.rows().count == 3)
    }

    @Test("Going idle writes one row, then nothing until the user comes back")
    func idleWritesOneRow() async throws {
        let harness = try Harness { $0.captureIdleSeconds = 120 }
        defer { harness.cleanUp() }

        harness.system.idle = 130
        for _ in 0..<4 {
            #expect(await harness.scheduler.tick().decision == .idle)
            harness.clock.advance(60)
        }
        #expect(try harness.rows().count == 1)
        #expect(try harness.rows()[0].skipReason == .idle)
        #expect(harness.capture.captureCount == 0)

        harness.system.idle = 0
        #expect(await harness.scheduler.tick().decision == .describedPending)
        #expect(try harness.rows().count == 2)
    }

    @Test("Idle right at the threshold counts as idle")
    func idleBoundary() async throws {
        let harness = try Harness { $0.captureIdleSeconds = 120 }
        defer { harness.cleanUp() }

        harness.system.idle = 119.9
        #expect(await harness.scheduler.tick().decision == .describedPending)
        harness.clock.advance(60)
        harness.system.idle = 120
        #expect(await harness.scheduler.tick().decision == .idle)
    }

    @Test("captureNow() overrides idle, because the user is demonstrably right there")
    func captureNowIgnoresIdle() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.system.idle = 10_000
        #expect(await harness.scheduler.captureNow().decision == .describedPending)
        #expect(harness.capture.captureCount == 1)
    }

    @Test("captureNow() still refuses to look at a locked screen")
    func captureNowRespectsLock() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.system.isLocked = true
        #expect(await harness.scheduler.captureNow().decision == .locked)
        #expect(harness.capture.captureCount == 0)
    }

    @Test("Sleep writes one asleep row, idle like a lock, and the decision stays locked (#313)")
    func sleepWritesAsleep() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.system.isAsleep = true
        for _ in 0..<3 {
            #expect(await harness.scheduler.tick().decision == .locked)
            harness.clock.advance(60)
        }
        let rows = try harness.rows()
        #expect(rows.map(\.skipReason) == [.asleep])
        #expect(rows[0].isIdle)
        #expect(harness.capture.captureCount == 0)
    }

    @Test("Locked alone writes locked; locked and asleep write asleep (#313)")
    func sleepOutranksLock() async throws {
        let locked = try Harness()
        defer { locked.cleanUp() }
        locked.system.isLocked = true
        _ = await locked.scheduler.tick()
        #expect(try locked.rows().map(\.skipReason) == [.locked])

        let both = try Harness()
        defer { both.cleanUp() }
        both.system.isLocked = true
        both.system.isAsleep = true
        _ = await both.scheduler.tick()
        #expect(try both.rows().map(\.skipReason) == [.asleep])
    }

    @Test("Waking to a locked screen writes asleep, then locked (#313)")
    func asleepThenLocked() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.system.isLocked = true
        harness.system.isAsleep = true
        _ = await harness.scheduler.tick()
        harness.clock.advance(60)
        harness.system.isAsleep = false
        _ = await harness.scheduler.tick()
        let rows = try harness.rows()
        #expect(rows.map(\.skipReason) == [.asleep, .locked])
        #expect(rows.map(\.isIdle) == [true, true])
    }

    // MARK: Privacy

    @Test("A blocked app is recorded without its title, URL or image")
    func blockedAppIsRedacted() async throws {
        let harness = try Harness(context: ForegroundContext(
            bundleID: "com.1password.1password", appName: "1Password", pid: 3,
            windowTitle: "Personal vault", browserURL: "https://vault.example.com/item/9"
        ))
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(result.decision == .blocked)

        let rows = try harness.rows()
        #expect(rows.count == 1)
        #expect(rows[0].isRedacted)
        #expect(rows[0].skipReason == .blockedBundle)
        #expect(rows[0].appBundleId == "com.1password.1password")
        #expect(rows[0].appName == "1Password")
        #expect(rows[0].windowTitle == nil)
        #expect(rows[0].browserUrl == nil)
        #expect(rows[0].urlHost == nil)
        #expect(rows[0].imagePath == nil)
        // The blocked app is never even photographed.
        #expect(harness.capture.captureCount == 0)
    }

    @Test("A continuous stretch in a blocked app writes one row, not one per tick")
    func blockedPeriodWritesOneRow() async throws {
        let harness = try Harness(context: ForegroundContext(
            bundleID: "com.1password.1password", appName: "1Password", pid: 3, windowTitle: "Vault"
        ))
        defer { harness.cleanUp() }

        for _ in 0..<3 {
            _ = await harness.scheduler.tick()
            harness.clock.advance(60)
        }
        #expect(try harness.rows().count == 1)
    }

    @Test("A blocked window title redacts even an app that is not on the bundle list")
    func blockedByTitle() async throws {
        let harness = try Harness(context: ForegroundContext(
            bundleID: "com.apple.Safari", appName: "Safari", pid: 4,
            windowTitle: "Bank — Private Browsing"
        ))
        defer { harness.cleanUp() }

        #expect(await harness.scheduler.tick().decision == .blocked)
        #expect(try harness.rows()[0].windowTitle == nil)
    }

    // MARK: Permission and budget

    @Test("Missing permission sets .permissionMissing and stops retrying for five minutes")
    func permissionMissingBacksOff() async throws {
        let harness = try Harness(capture: FakeCapture(permission: .denied))
        defer { harness.cleanUp() }

        #expect(await harness.scheduler.tick().decision == .error)
        #expect(harness.scheduler.state == .permissionMissing)
        #expect(try harness.rows().isEmpty)

        // Inside the back-off window the scheduler does not even ask.
        harness.capture.setPermission(.granted)
        harness.clock.advance(60)
        #expect(await harness.scheduler.tick().decision == .error)
        #expect(try harness.rows().isEmpty)

        harness.clock.advance(300)
        #expect(await harness.scheduler.tick().decision == .describedPending)
        #expect(harness.scheduler.state == .running)
    }

    @Test("Over budget still stores the frame, but never queues it for the vision model")
    func overBudgetSkipsDescribe() async throws {
        let harness = try Harness(costGate: OverBudgetGate())
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(result.savedImage)
        #expect(harness.scheduler.state == .budgetExceeded)
        // Not `describedPending`: nothing was queued, and the CLI's verbose line says so.
        #expect(result.decision == .budgetSkipped)

        let rows = try harness.rows()
        #expect(rows[0].imagePath != nil)
        #expect(rows[0].describeStatus == .skipped)
        #expect(rows[0].skipReason == .budget)
    }

    // MARK: Pause

    @Test("Pause writes nothing at all; a timed pause expires on its own")
    func pauseWritesNothing() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.scheduler.pause(for: 600)
        #expect(await harness.scheduler.tick().decision == .paused)
        #expect(try harness.rows().isEmpty)

        harness.clock.advance(601)
        #expect(await harness.scheduler.tick().decision == .describedPending)
        #expect(harness.scheduler.state == .running)
    }

    @Test("An open-ended pause holds until resume()")
    func indefinitePause() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.scheduler.pause(for: nil)
        harness.clock.advance(86_400)
        #expect(await harness.scheduler.tick().decision == .paused)

        harness.scheduler.resume()
        #expect(await harness.scheduler.tick().decision == .describedPending)
    }

    // MARK: A pause that outlives the process (#113)

    @Test("Pausing writes the deadline down; resuming takes it away")
    func pauseIsRecorded() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.scheduler.pause(for: 600)
        let stored = CaptureScheduler.storedPause(harness.db, now: harness.clock.now)
        #expect(stored == .until(harness.clock.now.addingTimeInterval(600)))

        harness.scheduler.resume()
        #expect(CaptureScheduler.storedPause(harness.db, now: harness.clock.now) == nil)
    }

    @Test("An open-ended pause records itself as \"until you resume\"")
    func indefinitePauseIsRecorded() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.scheduler.pause(for: nil)
        #expect(CaptureScheduler.storedPause(harness.db, now: harness.clock.now) == .untilResumed)
        // Quitting stops the scheduler; the pause has to survive exactly that.
        harness.scheduler.stop()
        #expect(CaptureScheduler.storedPause(harness.db, now: harness.clock.now) == .untilResumed)
    }

    @Test("A relaunch comes back paused, and the restored pause still expires on its own")
    func relaunchRestoresPause() async throws {
        let first = try Harness()
        defer { first.cleanUp() }
        first.scheduler.pause(for: 600)
        first.scheduler.stop()

        let second = try Harness(reusing: first.db, clock: first.clock, parkedLoop: true)
        defer { second.scheduler.stop(); second.cleanUp() }
        second.scheduler.startRestoringPause()
        #expect(second.scheduler.state == .paused(until: second.clock.now.addingTimeInterval(600)))
        #expect(await second.scheduler.tick().decision == .paused)
        #expect(try second.rows().isEmpty)

        second.clock.advance(601)
        #expect(await second.scheduler.tick().decision == .describedPending)
        #expect(second.scheduler.state == .running)
    }

    @Test("A deadline that passed while the app was down comes back capturing, and is forgotten")
    func expiredPauseDoesNotRestore() async throws {
        let first = try Harness()
        defer { first.cleanUp() }
        first.scheduler.pause(for: 600)
        first.scheduler.stop()
        first.clock.advance(3_600)

        let second = try Harness(reusing: first.db, clock: first.clock, parkedLoop: true)
        defer { second.scheduler.stop(); second.cleanUp() }
        second.scheduler.startRestoringPause()
        #expect(second.scheduler.state == .running)
        #expect(try AppStateStore(second.db).get(CaptureScheduler.pausedUntilKey) == nil)
    }

    @Test("A pause expiring inside a tick clears the record too")
    func expiryInsideATickClearsTheRecord() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.scheduler.pause(for: 600)
        harness.clock.advance(601)
        #expect(await harness.scheduler.tick().decision == .describedPending)
        #expect(try AppStateStore(harness.db).get(CaptureScheduler.pausedUntilKey) == nil)
    }

    @Test("Starting normally clears a pause nobody is in")
    func startClearsAStaleRecord() async throws {
        let harness = try Harness(parkedLoop: true)
        defer { harness.scheduler.stop(); harness.cleanUp() }

        harness.scheduler.pause(for: 600)
        harness.scheduler.start()
        #expect(try AppStateStore(harness.db).get(CaptureScheduler.pausedUntilKey) == nil)
    }

    @Test("Unreadable pause records are dropped rather than trusted")
    func malformedPauseRecordIsDropped() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        try AppStateStore(harness.db).set(CaptureScheduler.pausedUntilKey, "tomorrow-ish")
        #expect(CaptureScheduler.storedPause(harness.db, now: harness.clock.now) == nil)
        #expect(try AppStateStore(harness.db).get(CaptureScheduler.pausedUntilKey) == nil)
    }

    @Test("captureNow() overrides a pause — it is an explicit request")
    func captureNowOverridesPause() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.scheduler.pause(for: nil)
        #expect(await harness.scheduler.captureNow().decision == .describedPending)
    }

    // MARK: Two ticks in the same second (#63)

    @Test("A wake tick landing on a normal tick captures nothing")
    func wakeTickOnTopOfANormalTickIsTooSoon() async throws {
        let harness = try Harness { $0.captureIntervalSeconds = 60 }
        defer { harness.cleanUp() }

        #expect(await harness.scheduler.tick().decision == .describedPending)
        // `SystemStateMonitor.onWake` fires 10 s after wake while the loop's own sleep is already
        // due: outside a meeting nothing used to stop the second one.
        harness.clock.advance(3)
        #expect(await harness.scheduler.tick().decision == .tooSoon)
        #expect(try harness.rows().count == 1)
    }

    @Test("A tick past half the interval captures normally")
    func aLaterTickIsNotTooSoon() async throws {
        let harness = try Harness { $0.captureIntervalSeconds = 60 }
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        harness.clock.advance(40)
        #expect(await harness.scheduler.tick().decision != .tooSoon)
        #expect(try harness.rows().count == 2)
    }

    @Test("captureNow() is never too soon — it is an explicit request")
    func captureNowIgnoresTheThrottle() async throws {
        let harness = try Harness { $0.captureIntervalSeconds = 60 }
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        harness.clock.advance(3)
        #expect(await harness.scheduler.captureNow().decision != .tooSoon)
        #expect(try harness.rows().count == 2)
    }

    @Test("Half of the meeting interval applies while in a meeting")
    func theThrottleFollowsTheCurrentInterval() async throws {
        let harness = try Harness(
            configure: {
                $0.captureIntervalSeconds = 60
                $0.meetingCaptureIntervalSeconds = 300
            },
            context: ForegroundContext(
                bundleID: "us.zoom.xos", appName: "zoom.us", pid: 9, windowTitle: "Zoom Meeting"
            )
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        #expect(harness.meeting.isInMeeting)
        // Past half the normal interval, nowhere near half the meeting one.
        harness.clock.advance(40)
        #expect(await harness.scheduler.tick().decision == .tooSoon)
        harness.clock.advance(120)
        #expect(await harness.scheduler.tick().decision != .tooSoon)
    }

    @Test("The throttle holds for every CAPTURE_SOURCE mode", arguments: CaptureSourceMode.allCases)
    func tooSoonInEveryCaptureSource(mode: CaptureSourceMode) async throws {
        // `lastCaptureAt` moves on every persisted capture row, text-only ones included, so a
        // mode that never photographs is throttled the same way.
        let snapshotter = FakeSnapshotter(
            FakeSnapshotter.snapshot(coverage: .full, text: "Some window text")
        )
        let harness = try Harness(
            configure: {
                $0.captureIntervalSeconds = 60
                $0.captureSource = mode
            },
            snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        #expect(await harness.scheduler.tick().decision != .tooSoon)
        harness.clock.advance(3)
        #expect(await harness.scheduler.tick().decision == .tooSoon)
        #expect(try harness.rows().count == 1)
    }

    // MARK: Cadence

    @Test("The interval switches to the meeting cadence, jitter staying within 5%")
    func meetingInterval() async throws {
        let harness = try Harness {
            $0.captureIntervalSeconds = 60
            $0.meetingCaptureIntervalSeconds = 300
        }
        defer { harness.cleanUp() }

        for _ in 0..<20 {
            #expect((57...63).contains(harness.scheduler.currentInterval()))
        }

        harness.context.current = ForegroundContext(bundleID: "us.zoom.xos", appName: "zoom.us", pid: 9)
        _ = await harness.scheduler.tick()
        for _ in 0..<20 {
            #expect((285...315).contains(harness.scheduler.currentInterval()))
        }
    }

    @Test("Unplugging stretches the interval, and plugging back in restores it (#145)")
    func batteryInterval() async throws {
        let harness = try Harness(
            configure: {
                $0.captureIntervalSeconds = 60
                $0.captureOnBattery = .slow
            },
            parkedLoop: true
        )
        defer { harness.cleanUp() }
        harness.scheduler.start()
        defer { harness.scheduler.stop() }

        #expect((57...63).contains(harness.scheduler.currentInterval()))
        harness.system.setPower(PowerState(onBattery: true))
        #expect(harness.scheduler.power.onBattery)
        // 60 s × 5, with the same 5% jitter.
        #expect((285...315).contains(harness.scheduler.currentInterval()))

        harness.system.setPower(.mains)
        #expect((57...63).contains(harness.scheduler.currentInterval()))
    }

    @Test("each row records the interval it was taken at, so the timeline can join battery frames")
    func rowRecordsInterval() async throws {
        let harness = try Harness(
            configure: {
                $0.captureIntervalSeconds = 60
                $0.captureOnBattery = .slow
            },
            parkedLoop: true
        )
        defer { harness.cleanUp() }
        harness.scheduler.start()
        defer { harness.scheduler.stop() }

        _ = await harness.scheduler.tick()
        #expect(try harness.rows().last?.intervalSeconds == 60)

        harness.system.setPower(PowerState(onBattery: true))
        harness.clock.advance(300)
        _ = await harness.scheduler.tick()
        #expect(try harness.rows().last?.intervalSeconds == 300)
    }

    @Test("CAPTURE_ON_BATTERY=normal leaves the cadence alone on battery (#145)")
    func batteryIntervalNormal() async throws {
        let harness = try Harness(
            configure: {
                $0.captureIntervalSeconds = 60
                $0.captureOnBattery = .normal
            },
            parkedLoop: true
        )
        defer { harness.cleanUp() }
        harness.scheduler.start()
        defer { harness.scheduler.stop() }

        harness.system.setPower(PowerState(onBattery: true))
        #expect((57...63).contains(harness.scheduler.currentInterval()))
    }

    @Test("start() re-reads a charger that changed while the scheduler was stopped (#145)")
    func batteryReadOnStart() async throws {
        let harness = try Harness(
            configure: {
                $0.captureIntervalSeconds = 60
                $0.captureOnBattery = .slow
            },
            parkedLoop: true
        )
        defer { harness.cleanUp() }
        // Unplugged while stopped: no observers are registered, so no change ever fires.
        harness.system.power = PowerState(onBattery: true)
        harness.scheduler.start()
        defer { harness.scheduler.stop() }

        #expect(harness.scheduler.power.onBattery)
        #expect((285...315).contains(harness.scheduler.currentInterval()))
    }

    @Test("Low Power Mode on the charger eases off too (#145)")
    func lowPowerModeInterval() async throws {
        let harness = try Harness(
            configure: {
                $0.captureIntervalSeconds = 60
                $0.captureOnBattery = .slow
            },
            parkedLoop: true
        )
        defer { harness.cleanUp() }
        harness.scheduler.start()
        defer { harness.scheduler.stop() }

        harness.system.setPower(PowerState(onBattery: false, lowPowerMode: true))
        #expect((285...315).contains(harness.scheduler.currentInterval()))
    }

    @Test("A calendar meeting slows capture on its own, with no meeting app in the foreground")
    func calendarMeetingInterval() async throws {
        let harness = try Harness {
            $0.captureIntervalSeconds = 60
            $0.meetingCaptureIntervalSeconds = 300
        }
        defer { harness.cleanUp() }

        // Terminal in the foreground throughout: the only thing that says "meeting" is #22's
        // synced calendar event.
        let now = harness.clock.now
        #expect((57...63).contains(harness.scheduler.currentInterval()))

        harness.meeting.setContextEvents([
            ContextEvent(
                source: .calendar, externalId: "evt-1",
                startAt: now.addingTimeInterval(-600), endAt: now.addingTimeInterval(600),
                title: "Portfolio review", isMeeting: true
            ),
        ])
        _ = await harness.scheduler.tick()

        #expect(harness.meeting.isInMeeting)
        #expect(harness.meeting.currentMeeting?.title == "Portfolio review")
        for _ in 0..<20 {
            #expect((285...315).contains(harness.scheduler.currentInterval()))
        }
        // …and the frame that tick wrote is flagged, so the describer and the stats agree.
        #expect(try harness.rows().last?.isMeeting == true)
    }

    @Test("Once the calendar meeting is over, capture speeds back up")
    func calendarMeetingEnds() async throws {
        let harness = try Harness {
            $0.captureIntervalSeconds = 60
            $0.meetingCaptureIntervalSeconds = 300
        }
        defer { harness.cleanUp() }

        let now = harness.clock.now
        harness.meeting.setContextEvents([
            ContextEvent(
                source: .calendar, externalId: "evt-1",
                startAt: now.addingTimeInterval(-600), endAt: now.addingTimeInterval(60),
                title: "Standup", isMeeting: true
            ),
        ])
        _ = await harness.scheduler.tick()
        #expect((285...315).contains(harness.scheduler.currentInterval()))

        // Past the end, plus the two minutes of tolerance.
        harness.clock.advance(60 + MeetingDetector.calendarTolerance + 1)
        _ = await harness.scheduler.tick()
        #expect(!harness.meeting.isInMeeting)
        #expect((57...63).contains(harness.scheduler.currentInterval()))
    }

    @Test("A meeting tick records is_meeting on the row")
    func meetingFlagOnRow() async throws {
        let harness = try Harness(context: ForegroundContext(
            bundleID: "us.zoom.xos", appName: "zoom.us", pid: 9, windowTitle: "Zoom Meeting"
        ))
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        #expect(try harness.rows()[0].isMeeting)
    }

    @Test("A lock forgets the stored fingerprint, so the frame after unlock is described")
    func lockForgetsFingerprint() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        let stored: FrameFingerprint? = try harness.store.fetchLastFingerprint()
        #expect(stored != nil)

        harness.system.isLocked = true
        harness.clock.advance(60)
        _ = await harness.scheduler.tick()
        let afterLock: FrameFingerprint? = try harness.store.fetchLastFingerprint()
        #expect(afterLock == nil)

        // Same pixels as before the lock, and it is still described: continuity is broken.
        harness.system.isLocked = false
        harness.clock.advance(60)
        let resumed = await harness.scheduler.tick()
        #expect(resumed.decision == .describedPending)
        #expect(resumed.changeScore == nil)
    }

    // MARK: Restart

    @Test("A restart does not duplicate the row for an idle period already recorded")
    func restartHonoursTransitionRule() async throws {
        let harness = try Harness { $0.captureIdleSeconds = 120 }
        defer { harness.cleanUp() }

        harness.system.idle = 200
        _ = await harness.scheduler.tick()
        #expect(try harness.rows().count == 1)

        // A second scheduler over the same database, as if the app had been relaunched.
        let restarted = CaptureScheduler(
            config: {
                var config = Config.defaults()
                config.dataDir = harness.dataDir
                config.captureIdleSeconds = 120
                return config
            }(),
            db: harness.db,
            capture: harness.capture,
            context: harness.context,
            meeting: MeetingDetector(),
            system: harness.system,
            clock: InstantClock(),
            now: { harness.clock.now }
        )
        restarted.start()
        defer { restarted.stop() }

        #expect(await restarted.tick().decision == .idle)
        #expect(try harness.rows().count == 1)
    }

    @Test("A restart inside a blocked stretch does not write a second redacted row")
    func restartHonoursBlockedRule() async throws {
        let blocked = ForegroundContext(
            bundleID: "com.1password.1password", appName: "1Password", pid: 3, windowTitle: "Vault"
        )
        let harness = try Harness(context: blocked)
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        #expect(try harness.rows().count == 1)

        var config = Config.defaults()
        config.dataDir = harness.dataDir
        let restarted = CaptureScheduler(
            config: config, db: harness.db, capture: harness.capture, context: harness.context,
            meeting: MeetingDetector(), system: harness.system,
            clock: InstantClock(), now: { harness.clock.now }
        )
        restarted.start()
        defer { restarted.stop() }

        #expect(await restarted.tick().decision == .blocked)
        #expect(try harness.rows().count == 1)

        // A different blocked app is still its own row.
        harness.context.current = ForegroundContext(
            bundleID: "com.apple.keychainaccess", appName: "Keychain Access", pid: 4
        )
        #expect(await restarted.tick().decision == .blocked)
        #expect(try harness.rows().count == 2)
    }
}

// MARK: - The accessibility snapshot in the tick (#53)

private let fullOutline = String(repeating: "[AXStaticText] #general — Ana: standup at ten. ", count: 4)

@MainActor
@Suite("CaptureScheduler with an accessibility snapshot")
struct CaptureSchedulerAXTests {
    @Test("A walked frame stores its redacted outline and says it carries both artifacts")
    func fullSnapshotStored() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(
            coverage: .full, text: fullOutline, documentURL: "file:///Users/x/notes.md"
        ))
        let harness = try Harness(
            configure: { $0.captureSource = .both }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        let rows = try harness.rows()
        #expect(rows.count == 1)
        #expect(rows[0].captureSource == .both)
        // `both` takes the screenshot every tick, whatever the walk found.
        #expect(result.savedImage)

        let ax = try harness.axRow(rows[0].id)
        #expect(ax?.coverage == .full)
        #expect(ax?.nodeCount == 40)
        #expect(ax?.text == fullOutline)
        #expect(ax?.textChars == fullOutline.count)
        #expect(ax?.documentUrl == "file:///Users/x/notes.md")
        #expect(ax?.redactionsJson == nil)
        // The walk was asked about the frontmost process, not about a display.
        #expect(snapshotter.pids == [1])
    }

    @Test("#311: a Chrome tab's AXDocument is stored stripped, and not at all with browser URLs off",
          arguments: [true, false])
    func browserDocumentURLFollowsTheTabURLRule(collect: Bool) async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(
            coverage: .full, text: fullOutline,
            documentURL: "https://Mail.Example.com/inbox?token=abc123#msg-9"
        ))
        let harness = try Harness(
            configure: { $0.captureSource = .both; $0.collectBrowserURL = collect },
            context: ForegroundContext(
                bundleID: "com.google.Chrome", appName: "Google Chrome", pid: 1, windowTitle: "Inbox"
            ),
            snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        let ax = try harness.axRow(try harness.rows()[0].id)
        #expect(ax != nil)
        #expect(ax?.documentUrl == (collect ? "https://mail.example.com/inbox" : nil))
    }

    @Test("The stored hash is over the redacted text, and the credential is not in the row")
    func hashIsOverRedactedText() async throws {
        let raw = fullOutline + "[AXTextField] senha=hunter2 [AXStaticText] card 4111 1111 1111 1111"
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(coverage: .full, text: raw))
        let harness = try Harness(
            configure: { $0.captureSource = .both }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        let ax = try harness.axRow(try harness.rows()[0].id)

        let stored = try #require(ax?.text)
        #expect(!stored.contains("hunter2"))
        #expect(!stored.contains("4111"))
        #expect(stored.contains("[PASSWORD]"))
        #expect(ax?.redactionsJson == #"{"card":1,"password":1}"#)
        // The hash is the redacted text's, not the walk's — the row and its hash always agree.
        #expect(ax?.textHash == AXOutline.hash(stored))
        #expect(ax?.textHash != AXOutline.hash(raw))
        #expect(try harness.storedAXHash() == ax?.textHash)
    }

    @Test("A full frame whose text did not move is not described, however much the pixels moved")
    func fullUnchangedTextSkipsDescribe() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(coverage: .full, text: fullOutline))
        let harness = try Harness(
            configure: { $0.captureSource = .both }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        // A video playing: every pixel different, the window's text identical.
        harness.capture.setGray(0.9)
        harness.clock.advance(60)
        let second = await harness.scheduler.tick()

        #expect(second.decision == .unchanged)
        #expect(second.savedImage == false)
        #expect((second.changeScore ?? 0) > 0.03)
        let rows = try harness.rows()
        #expect(rows[1].describeStatus == .inherited)
        // The row is still written, and still says it carries a snapshot.
        #expect(rows[1].captureSource == .both)
        #expect(try harness.axRows().count == 2)
    }

    @Test("A full frame whose text moved is described, even with identical pixels")
    func fullChangedTextForcesDescribe() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(coverage: .full, text: fullOutline))
        let harness = try Harness(
            configure: { $0.captureSource = .both }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        // A new message in the same window: the pixels barely move, the outline does.
        snapshotter.setText(fullOutline + "[AXStaticText] Bruno: on my way.")
        harness.clock.advance(60)
        let second = await harness.scheduler.tick()

        #expect(second.decision == .describedPending)
        #expect(second.savedImage)
        #expect(try harness.storedAXHash() == (try harness.axRow(second.captureId!))?.textHash)
    }

    @Test("A partial frame keeps the pixel rule underneath the text hash")
    func partialKeepsPixelRule() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(
            coverage: .partial, text: fullOutline, nodes: 400
        ))
        let harness = try Harness(
            configure: { $0.captureSource = .both }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        harness.capture.setGray(0.9)
        harness.clock.advance(60)
        let second = await harness.scheduler.tick()

        // Same unmoved text as the `.full` case, and this time the pixels win.
        #expect(second.decision == .describedPending)
        #expect(try harness.axRow(second.captureId!)?.coverage == .partial)
    }

    @Test("A coverage of none stores the row, remembers no hash, and changes no decision")
    func noneCoverageIsInert() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(
            coverage: AXSnapshot.Coverage.none, text: "", nodes: 0, elapsedMs: 398
        ))
        let harness = try Harness(
            configure: { $0.captureSource = .both }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        harness.clock.advance(60)
        let second = await harness.scheduler.tick()

        // Today's rule, untouched: identical pixels, so nothing is described.
        #expect(second.decision == .unchanged)
        let ax = try #require(try harness.axRow(second.captureId!))
        #expect(ax.coverage == AXSnapshot.Coverage.none)
        #expect(ax.text == nil)
        #expect(ax.elapsedMs == 398)
        // Nothing worth comparing against, so nothing is remembered.
        #expect(try harness.storedAXHash() == nil)
    }

    @Test("Without a snapshotter — or without the grant — the row says screenshot and no outline exists")
    func noSnapshotterIsUnchanged() async throws {
        // `snapshot(pid:)` answering nil is exactly what the live snapshotter does when
        // Accessibility is not granted.
        let denied = FakeSnapshotter(nil)
        let harness = try Harness(
            configure: { $0.captureSource = .both }, snapshotter: denied
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        let rows = try harness.rows()
        #expect(rows[0].captureSource == .screenshot)
        #expect(try harness.axRows().isEmpty)
        #expect(try harness.storedAXHash() == nil)
    }

    @Test("A blocked app is never walked")
    func blockedAppIsNotWalked() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(coverage: .full, text: fullOutline))
        let harness = try Harness(
            configure: {
                $0.blockedBundleIDs = ["com.apple.Terminal"]
                $0.captureSource = .both
            },
            snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(result.decision == .blocked)
        #expect(snapshotter.pids.isEmpty)
        #expect(try harness.axRows().isEmpty)
    }

    @Test("Switching app forgets the hash and turns AXEnhancedUserInterface back off")
    func bundleSwitchClearsHashAndResetsSwitch() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(
            coverage: .full, text: fullOutline, setEnhanced: true
        ))
        let harness = try Harness(
            configure: { $0.captureSource = .both }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        #expect(try harness.storedAXHash() != nil)
        #expect(snapshotter.resetPids.isEmpty)

        harness.context.current = ForegroundContext(
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", pid: 42, windowTitle: "#general"
        )
        harness.clock.advance(60)
        let second = await harness.scheduler.tick()

        // The switch was turned back off on the app it was set on, not on the new one.
        #expect(snapshotter.resetPids == [1])
        // A new app means nothing to compare against, so the frame is described.
        #expect(second.decision == .describedPending)
        #expect(snapshotter.pids == [1, 42])
    }

    @Test("A lock forgets the text hash too, so the frame after unlock is described")
    func lockForgetsTextHash() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(coverage: .full, text: fullOutline))
        let harness = try Harness(
            configure: { $0.captureSource = .both }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        #expect(try harness.storedAXHash() != nil)

        harness.system.isLocked = true
        harness.clock.advance(60)
        _ = await harness.scheduler.tick()
        #expect(try harness.storedAXHash() == nil)

        harness.system.isLocked = false
        harness.clock.advance(60)
        let back = await harness.scheduler.tick()
        #expect(back.decision == .describedPending)
    }

    @Test("A restart compares against the hash the last run left behind")
    func hashSurvivesARestart() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(coverage: .full, text: fullOutline))
        let harness = try Harness(
            configure: { $0.captureSource = .both }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        let stored = try #require(try harness.storedAXHash())

        // A second scheduler over the same database is what a relaunch looks like.
        let restarted = CaptureScheduler(
            config: {
                var c = Config.defaults()
                c.dataDir = harness.dataDir
                c.collectBrowserURL = false
                c.captureSource = .both
                return c
            }(),
            db: harness.db,
            capture: harness.capture,
            context: harness.context,
            meeting: harness.meeting,
            system: harness.system,
            snapshotter: snapshotter,
            clock: InstantClock(),
            now: { harness.clock.now }
        )
        harness.clock.advance(60)
        let result = await restarted.tick()

        #expect(result.decision == .unchanged)
        #expect(try harness.storedAXHash() == stored)
    }

}

// MARK: - CAPTURE_SOURCE (#54)

@MainActor
@Suite("CaptureScheduler and CAPTURE_SOURCE")
struct CaptureSourceModeTests {
    private func harness(
        _ source: CaptureSourceMode,
        coverage: AXSnapshot.Coverage = .full,
        text: String = fullOutline,
        nodes: Int = 40,
        snapshotter: FakeSnapshotter? = nil
    ) throws -> Harness {
        try Harness(
            configure: { $0.captureSource = source },
            snapshotter: snapshotter ?? FakeSnapshotter(FakeSnapshotter.snapshot(
                coverage: coverage, text: text, nodes: nodes
            ))
        )
    }

    @Test("auto: a fully covered window is never photographed")
    func autoFullTakesNoScreenshot() async throws {
        let harness = try harness(.auto)
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(harness.capture.captureCount == 0)
        #expect(result.decision == .describedPending)
        #expect(result.savedImage == false)

        let row = try #require(try harness.rows().first)
        #expect(row.captureSource == .accessibility)
        #expect(row.imagePath == nil)
        #expect(row.dhash == nil)
        #expect(row.changeScore == nil)
        #expect(row.describeStatus == .pending)
        // No `.jpg` on disk for it — the whole point of the mode.
        #expect(try harness.jpegCount() == 0)
        // …and the outline is there for the describer to read.
        #expect(try harness.axRow(row.id)?.text == fullOutline)
    }

    @Test("auto: a partly covered window still gets its picture")
    func autoPartialTakesTheScreenshot() async throws {
        let harness = try harness(.auto, coverage: .partial, nodes: 400)
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(harness.capture.captureCount == 1)
        #expect(result.savedImage)
        let row = try #require(try harness.rows().first)
        #expect(row.captureSource == .both)
        #expect(row.imagePath != nil)
    }

    @Test("auto: a window that exposes nothing falls back to today's pipeline")
    func autoNoneFallsBackToPixels() async throws {
        let harness = try harness(
            .auto, coverage: AXSnapshot.Coverage.none, text: "", nodes: 0
        )
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(harness.capture.captureCount == 1)
        #expect(result.savedImage)
        #expect(try harness.rows().first?.captureSource == .both)
    }

    @Test("auto: no grant means no snapshot, and the picture is taken as before")
    func autoWithoutTheGrant() async throws {
        let harness = try Harness(
            configure: { $0.captureSource = .auto }, snapshotter: FakeSnapshotter(nil)
        )
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(harness.capture.captureCount == 1)
        #expect(result.savedImage)
        #expect(try harness.rows().first?.captureSource == .screenshot)
        #expect(try harness.axRows().isEmpty)
    }

    @Test("auto: a text-only frame is not re-described until its text moves")
    func autoTextOnlyDecision() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(coverage: .full, text: fullOutline))
        let harness = try Harness(
            configure: { $0.captureSource = .auto }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        #expect(await harness.scheduler.tick().decision == .describedPending)
        harness.clock.advance(60)
        // Same outline, and no pixels to disagree with it.
        let second = await harness.scheduler.tick()
        #expect(second.decision == .unchanged)
        #expect(try harness.rows()[1].describeStatus == .inherited)

        snapshotter.setText(fullOutline + "[AXStaticText] Bruno: on my way.")
        harness.clock.advance(60)
        #expect(await harness.scheduler.tick().decision == .describedPending)
        #expect(harness.capture.captureCount == 0)
    }

    @Test("auto: the heartbeat still fires without pixels")
    func autoHeartbeat() async throws {
        let harness = try harness(.auto)
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        harness.clock.advance(60)
        #expect(await harness.scheduler.tick().decision == .unchanged)
        // Past CAPTURE_HEARTBEAT_SECONDS: describe it again even though nothing moved.
        harness.clock.advance(400)
        #expect(await harness.scheduler.tick().decision == .describedPending)
    }

    @Test("screenshot: the tree is never read at all")
    func screenshotNeverWalks() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(coverage: .full, text: fullOutline))
        let harness = try Harness(
            configure: { $0.captureSource = .screenshot }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(snapshotter.pids.isEmpty)
        #expect(harness.capture.captureCount == 1)
        #expect(result.savedImage)
        #expect(try harness.rows().first?.captureSource == .screenshot)
        #expect(try harness.axRows().isEmpty)
        #expect(try harness.storedAXHash() == nil)
    }

    @Test("both: a walk and a picture every tick, whatever the coverage")
    func bothCollectsEverything() async throws {
        let snapshotter = FakeSnapshotter(FakeSnapshotter.snapshot(coverage: .full, text: fullOutline))
        let harness = try Harness(
            configure: { $0.captureSource = .both }, snapshotter: snapshotter
        )
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(snapshotter.pids == [1])
        #expect(harness.capture.captureCount == 1)
        #expect(result.savedImage)
        let row = try #require(try harness.rows().first)
        #expect(row.captureSource == .both)
        #expect(row.imagePath != nil)
        #expect(try harness.axRow(row.id)?.text == fullOutline)
    }

    @Test("accessibility: a window with no text is recorded as skipped/no_text, once per stretch")
    func accessibilityWithoutText() async throws {
        let harness = try harness(
            .accessibility, coverage: AXSnapshot.Coverage.none, text: "", nodes: 0
        )
        defer { harness.cleanUp() }

        let first = await harness.scheduler.tick()
        #expect(first.decision == .noText)
        #expect(harness.capture.captureCount == 0)
        let row = try #require(try harness.rows().first)
        #expect(row.skipReason == .noText)
        #expect(row.describeStatus == .skipped)
        #expect(row.captureSource == .accessibility)
        #expect(row.imagePath == nil)
        // Not idle: an unreadable window is not an absent user, and the timeline must not
        // colour it the way it colours a break.
        #expect(row.isIdle == false)
        #expect(row.appName == "Terminal")

        // A second tick in the same app writes nothing more.
        harness.clock.advance(60)
        #expect(await harness.scheduler.tick().decision == .noText)
        #expect(try harness.rows().count == 1)

        // A different app is its own row.
        harness.context.current = ForegroundContext(
            bundleID: "com.figma.Desktop", appName: "Figma", pid: 7, windowTitle: "Board"
        )
        harness.clock.advance(60)
        #expect(await harness.scheduler.tick().decision == .noText)
        #expect(try harness.rows().count == 2)
    }

    @Test("accessibility: no Accessibility grant means no frames, not silent screenshots")
    func accessibilityWithoutTheGrant() async throws {
        let harness = try Harness(
            configure: { $0.captureSource = .accessibility }, snapshotter: FakeSnapshotter(nil)
        )
        defer { harness.cleanUp() }

        #expect(await harness.scheduler.tick().decision == .noText)
        #expect(harness.capture.captureCount == 0)
        #expect(try harness.rows().first?.skipReason == .noText)
    }

    @Test("accessibility: a partly covered window is described from its text alone")
    func accessibilityPartialIsStillDescribed() async throws {
        let harness = try harness(.accessibility, coverage: .partial, nodes: 400)
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(result.decision == .describedPending)
        #expect(harness.capture.captureCount == 0)
        let row = try #require(try harness.rows().first)
        #expect(row.captureSource == .accessibility)
        #expect(row.imagePath == nil)
    }

}

// MARK: - Metadata provenance (#55)

@Suite("Capture metadata sources")
@MainActor
struct CaptureMetadataSourceTests {
    private func context(
        bundleID: String,
        url: String? = nil,
        titleSource: ForegroundContext.Source,
        urlSource: ForegroundContext.Source
    ) -> ForegroundContext {
        ForegroundContext(
            bundleID: bundleID, appName: bundleID, pid: 1, windowTitle: "A window",
            browserURL: url, urlHost: url == nil ? nil : "example.com",
            titleSource: titleSource, urlSource: urlSource
        )
    }

    @Test("The row records which reader answered")
    func rowsCarryTheSources() async throws {
        let harness = try Harness(
            context: context(
                bundleID: "com.google.Chrome", url: "https://example.com/a",
                titleSource: .ax, urlSource: .ax
            )
        )
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()

        // A browser frame only the probes could name: no Accessibility grant for this app.
        harness.context.current = context(
            bundleID: "com.apple.Safari", url: "https://example.com/b",
            titleSource: .windowList, urlSource: .applescript
        )
        harness.clock.advance(60)
        harness.capture.setGray(0.2)
        _ = await harness.scheduler.tick()

        // A non-browser frame: it has no URL to read, so it belongs in the title split only.
        harness.context.current = context(
            bundleID: "com.apple.Terminal", titleSource: .ax, urlSource: .none
        )
        harness.clock.advance(60)
        harness.capture.setGray(0.8)
        _ = await harness.scheduler.tick()

        let day = DayBoundaries.dayString(harness.clock.now)
        let rows = try CaptureStore(harness.db).fetch(day: day)
        #expect(rows.map(\.titleSource) == [.ax, .windowList, .ax])
        #expect(rows.map(\.urlSource) == [.ax, .applescript, ForegroundContext.Source.none])
    }

    @Test("A blocked frame keeps neither field")
    func blockedFramesAreNotCounted() async throws {
        let harness = try Harness(
            configure: { $0.blockedBundleIDs = ["com.agilebits.onepassword7"] },
            context: context(
                bundleID: "com.agilebits.onepassword7", titleSource: .ax, urlSource: .none
            )
        )
        defer { harness.cleanUp() }

        let result = await harness.scheduler.tick()
        #expect(result.decision == .blocked)

        let day = DayBoundaries.dayString(harness.clock.now)
        let rows = try CaptureStore(harness.db).fetch(day: day)
        #expect(rows.count == 1)
        #expect(rows.first?.titleSource == nil)
        #expect(rows.first?.urlSource == nil)
    }
}

// MARK: - Coverage transitions (#146)

@Suite("Coverage transitions")
@MainActor
struct CoverageTransitionTests {
    private func events(_ harness: Harness) throws -> [CoverageEvent] {
        try CoverageEventStore(harness.db).events(from: .distantPast, to: .distantFuture)
    }

    @Test("Start, pause, resume and stop each leave a row")
    func transitionsAreRecorded() async throws {
        // The real loop, parked on its first sleep: `start()` is the transition under test.
        let harness = try Harness(parkedLoop: true)
        defer { harness.cleanUp() }

        harness.scheduler.start()
        harness.scheduler.stop()
        harness.clock.advance(60)
        harness.scheduler.pause(for: 900)
        harness.clock.advance(60)
        harness.scheduler.resume()

        let written = try events(harness)
        #expect(written.map(\.coverageKind) == [.started, .stopped, .paused, .resumed])
        #expect(written[2].coverageReason == .user)
    }

    @Test("A pause the same as the last one is not written twice")
    func dedupes() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.scheduler.pause(for: 900)
        harness.clock.advance(10)
        harness.scheduler.pause(for: 1800)
        #expect(try events(harness).count == 1)
    }

    @Test("A scheduler that never started writes no stopped when it is stopped (#313)")
    func neverStartedWritesNothing() async throws {
        // A second copy of the app quits at launch through the same `shutdown()` as a real quit,
        // over the database the running copy is writing to.
        let running = try Harness(parkedLoop: true)
        defer { running.cleanUp() }
        running.scheduler.start()
        running.clock.advance(60)

        let second = try Harness(reusing: running.db, clock: running.clock, parkedLoop: true)
        defer { second.cleanUp() }
        second.scheduler.stop()
        #expect(try events(running).map(\.coverageKind) == [.started])

        running.scheduler.stop()
    }

    @Test("A started, or started and paused, scheduler still writes stopped (#313)")
    func ranWritesStopped() async throws {
        let harness = try Harness(parkedLoop: true)
        defer { harness.cleanUp() }

        harness.scheduler.start()
        harness.clock.advance(60)
        harness.scheduler.pause(for: 900)
        harness.clock.advance(60)
        harness.scheduler.stop()
        harness.clock.advance(60)
        harness.scheduler.start()
        harness.clock.advance(60)
        harness.scheduler.stop()

        #expect(
            try events(harness).map(\.coverageKind) == [.started, .paused, .stopped, .started, .stopped]
        )
    }

    @Test("A missing Screen Recording grant is recorded, and the grant coming back closes it")
    func permissionIsRecorded() async throws {
        let capture = FakeCapture(permission: .denied)
        let harness = try Harness(capture: capture)
        defer { harness.cleanUp() }

        _ = await harness.scheduler.tick()
        // The retry window is five minutes, and the state does not change in between: one row.
        harness.clock.advance(CaptureScheduler.permissionRetryInterval + 1)
        _ = await harness.scheduler.tick()
        #expect(try events(harness).map(\.coverageKind) == [.paused])
        #expect(try events(harness).first?.coverageReason == .permissionMissing)

        capture.setPermission(.granted)
        harness.clock.advance(CaptureScheduler.permissionRetryInterval + 1)
        _ = await harness.scheduler.tick()
        #expect(try events(harness).map(\.coverageKind) == [.paused, .resumed])
    }

    @Test("A run that never stopped is closed at its last frame when the app comes back")
    func crashedRunIsClosed() async throws {
        let harness = try Harness(parkedLoop: true)
        defer { harness.cleanUp() }

        harness.scheduler.start()
        _ = await harness.scheduler.tick()
        let lastFrame = try #require(try harness.rows().last?.capturedAt)

        // A second scheduler over the same database, as if the app had been killed and relaunched.
        harness.clock.advance(3_600)
        var config = Config.defaults()
        config.dataDir = harness.dataDir
        let clock = harness.clock
        let restarted = CaptureScheduler(
            config: config,
            db: harness.db,
            capture: FakeCapture(),
            context: harness.context,
            meeting: harness.meeting,
            system: FakeSystemState(),
            clock: ParkedClock(),
            now: { clock.now }
        )
        restarted.start()
        defer { restarted.stop() }

        let written = try events(harness)
        #expect(written.map(\.coverageKind) == [.started, .stopped, .started])
        #expect(written[1].at == lastFrame)
    }
}
