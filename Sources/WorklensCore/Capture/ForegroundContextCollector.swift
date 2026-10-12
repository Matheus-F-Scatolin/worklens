import AppKit
import CoreGraphics
import Foundation

// MARK: - Context

/// The free metadata around one capture tick: which app is in front, what its window is called,
/// and — for browsers — which page it is on. No vision call needed, so this runs on every tick
/// and decides whether a vision call is needed at all.
public struct ForegroundContext: Codable, Sendable, Equatable {
    /// Where one of the two metadata fields came from (#55). Kept for the menu's browser-URL line
    /// and for debug logs, and for nothing else: no report, timeline or prompt reads it, and the
    /// describe pipeline cannot tell an accessibility title from a window-list one.
    public enum Source: String, Codable, Sendable, Equatable, CaseIterable {
        /// The focused window's own `AXTitle` / `AXURL` — no Screen Recording, no Apple Events.
        case ax
        /// `kCGWindowName` from `CGWindowListCopyWindowInfo`, which needs Screen Recording.
        case windowList
        /// The per-browser AppleScript probe, which prompts once per browser and skips Firefox.
        case applescript
        /// Nothing had it: no grant, no window, or an app that exposes no title at all.
        case none
    }

    public var bundleID: String?
    public var appName: String?
    public var pid: Int32
    public var windowTitle: String?
    /// Scheme + host + path; the query is included only when `URL_STORE_QUERY` is on.
    public var browserURL: String?
    /// Lowercased host, kept separately so the timeline can group by site cheaply.
    public var urlHost: String?
    /// Which of the two title readers supplied `windowTitle` (#55).
    public var titleSource: Source
    /// Which of the two URL readers supplied `browserURL` (#55). `.none` for every app that is
    /// not a known browser, and whenever `COLLECT_BROWSER_URL` is off (`policySite` may still
    /// have been read).
    public var urlSource: Source
    public var collectedAt: Date
    /// What the privacy policy knows about the frontmost tab's site, read for `BLOCKED_URL_HOSTS`
    /// and for nothing else. Filled even when `COLLECT_BROWSER_URL` is off (then `browserURL` and
    /// `urlHost` stay nil), so turning URL collection off cannot turn the host blocklist off with
    /// it. Nil for every app that is not a known browser. Never written to a row, never part of
    /// `signature`, and left out of `Codable` on purpose.
    public var policySite: PolicySite?

    /// The frontmost tab as the host blocklist sees it.
    public enum PolicySite: Equatable, Sendable {
        /// The address was read and has this (lowercased) host.
        case host(String)
        /// The address was read and has no host at all: `about:blank`, a `file:` page.
        case noHost
        /// A known browser whose address could not be read — no Automation grant, Firefox
        /// without an accessibility URL, a timed-out probe. The host blocklist fails closed on it.
        case unreadable

        public var host: String? {
            if case let .host(host) = self { return host }
            return nil
        }
    }

    /// `policySite` is deliberately missing: it exists for the policy check alone.
    private enum CodingKeys: String, CodingKey {
        case bundleID, appName, pid, windowTitle, browserURL, urlHost, titleSource, urlSource
        case collectedAt
    }

    public init(
        bundleID: String? = nil,
        appName: String? = nil,
        pid: Int32 = 0,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        urlHost: String? = nil,
        titleSource: Source = .none,
        urlSource: Source = .none,
        collectedAt: Date = Date(),
        policySite: PolicySite? = nil
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.pid = pid
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.urlHost = urlHost
        self.titleSource = titleSource
        self.urlSource = urlSource
        self.collectedAt = collectedAt
        self.policySite = policySite
    }

    /// Stable string behind "did the context change?": `bundleID|windowTitle|host+path`.
    ///
    /// Deliberately excludes `pid` and `collectedAt` — relaunching an app or simply time passing
    /// is not a context change, and treating it as one would force a needless vision call.
    public var signature: String {
        let site = ForegroundContext.hostAndPath(browserURL) ?? "-"
        return "\(bundleID ?? "-")|\(windowTitle ?? "-")|\(site)"
    }

    /// Host + path of a URL, without scheme or query, for signature comparisons.
    static func hostAndPath(_ url: String?) -> String? {
        guard let url, let components = URLComponents(string: url) else { return url }
        guard let host = components.host else { return url }
        return "\(host.lowercased())\(components.path)"
    }
}

// MARK: - Collector

/// What the scheduler needs from context collection. `CaptureScheduler` depends on this rather
/// than the concrete collector so its tests can drive app switches without an actual desktop.
public protocol ForegroundContextProviding: Sendable {
    func collect() -> ForegroundContext

    /// The context plus the accessibility header it was built from (#55), so the tick can hand
    /// the window it already found to the walk instead of looking it up a second time.
    func collectWithHeader() -> ForegroundReading
}

public extension ForegroundContextProviding {
    /// Default for a provider with no accessibility read of its own — every fake, and the CLI
    /// paths that only want the metadata.
    func collectWithHeader() -> ForegroundReading {
        ForegroundReading(context: collect(), header: nil)
    }
}

/// One `collect()`, with the accessibility elements it resolved on the way. `header` is nil
/// whenever Accessibility is not granted, which is also the shape every fake provider has.
public struct ForegroundReading: Sendable {
    public let context: ForegroundContext
    public let header: AXHeader?

    public init(context: ForegroundContext, header: AXHeader?) {
        self.context = context
        self.header = header
    }
}

/// Reads the foreground context from the OS. Cheap by design: `NSWorkspace`, the focused window's
/// accessibility header when that grant exists, and — only as fallbacks — one
/// `CGWindowListCopyWindowInfo` call and, for browsers with `COLLECT_BROWSER_URL` on or
/// `BLOCKED_URL_HOSTS` set, AppleScript.
public final class ForegroundContextCollector: ForegroundContextProviding, @unchecked Sendable {
    private let config: Config
    private let scripting: BrowserURLScripting
    private let headers: (any AXHeaderProviding)?

    public init(config: Config) {
        self.config = config
        self.scripting = AppleScriptBrowserURL()
        // Returns nil until the Accessibility grant exists, so this costs nothing without it.
        self.headers = AccessibilitySnapshotter()
    }

    /// Test seam: `BrowserURLScripting` stands in for the AppleScript round trip and
    /// `AXHeaderProviding` for the accessibility read.
    init(config: Config, scripting: BrowserURLScripting, headers: (any AXHeaderProviding)? = nil) {
        self.config = config
        self.scripting = scripting
        self.headers = headers
    }

    public func collect() -> ForegroundContext { collectWithHeader().context }

    public func collectWithHeader() -> ForegroundReading {
        let now = Date()
        guard let app = NSWorkspace.shared.frontmostApplication else {
            // The login window and fast-user-switching leave no frontmost app.
            return ForegroundReading(
                context: ForegroundContext(appName: "unknown", collectedAt: now), header: nil
            )
        }
        let bundleID = app.bundleIdentifier
        let pid = app.processIdentifier
        // Ahead of the blocklist by design (#55): the title and the host it matches on are what
        // the blocklist needs, and this is the read that has them without Screen Recording.
        let header = headers?.header(pid: pid)

        let resolved = ForegroundContextCollector.resolve(
            bundleID: bundleID,
            header: header,
            // Lazy: with an accessibility title there is no reason to pay for the window list.
            windowListTitle: { ForegroundContextCollector.windowTitle(pid: pid) },
            config: config,
            scripting: scripting
        )

        return ForegroundReading(
            context: ForegroundContext(
                bundleID: bundleID,
                appName: app.localizedName,
                pid: pid,
                windowTitle: resolved.windowTitle,
                browserURL: resolved.browserURL,
                urlHost: resolved.urlHost,
                titleSource: resolved.titleSource,
                urlSource: resolved.urlSource,
                collectedAt: now,
                policySite: resolved.policySite
            ),
            header: header
        )
    }

    /// What the two readers produced, and which one it came from.
    struct Resolved: Equatable {
        var windowTitle: String?
        var browserURL: String?
        var urlHost: String?
        var titleSource: ForegroundContext.Source = .none
        var urlSource: ForegroundContext.Source = .none
        /// The site for the policy check alone; see `ForegroundContext.policySite`.
        var policySite: ForegroundContext.PolicySite?
    }

    /// The precedence, as a pure function of the header and the two fallbacks, so it is tested
    /// with fixtures instead of against whatever app happens to be in front.
    ///
    /// Accessibility first for both fields, then today's probes: `kCGWindowName` for the title
    /// (Screen Recording) and the per-browser AppleScript for the URL (Apple Events, and nothing
    /// at all for Firefox). Neither probe is removed — a header is missing whenever the grant is
    /// missing, and an individual attribute can be absent on a window that has the rest.
    static func resolve(
        bundleID: String?,
        header: AXHeader?,
        windowListTitle: () -> String?,
        config: Config,
        scripting: BrowserURLScripting
    ) -> Resolved {
        var resolved = Resolved()

        if let title = header?.windowTitle?.nonEmpty {
            resolved.titleSource = .ax
            resolved.windowTitle = title
        } else if let title = windowListTitle()?.nonEmpty {
            resolved.titleSource = .windowList
            resolved.windowTitle = title
        }
        // For Firefox, and for any browser whose AppleScript is unavailable, the page title is
        // the only thing left — so keep it clean rather than "Page — Mozilla Firefox".
        resolved.windowTitle = BrowserRegistry.strippedTitle(resolved.windowTitle, bundleID: bundleID)

        guard let browser = BrowserRegistry.browser(forBundleID: bundleID) else { return resolved }
        // A browser is in front, so the host blocklist has a question to ask. Until a reader
        // answers it, the answer is "unreadable", which the policy treats as blocked whenever
        // `BLOCKED_URL_HOSTS` is set (security finding #4).
        resolved.policySite = .unreadable

        // `COLLECT_BROWSER_URL` decides what is *kept*; `BLOCKED_URL_HOSTS` still needs to know
        // which site is in front. With the first off and the second set, the address is read
        // here, its host handed to the policy, and the rest dropped.
        guard config.collectBrowserURL || !config.blockedURLHosts.isEmpty else { return resolved }

        // The same normalization for both readers — the stored URL and the host the timeline
        // groups by must not depend on which one answered. Query strings are always stripped
        // (#87): they carry search terms and session tokens, and nothing here needs them.
        var read: (normalized: BrowserRegistry.NormalizedURL, source: ForegroundContext.Source)?
        if let normalized = BrowserRegistry.normalize(header?.webURL) {
            read = (normalized, .ax)
        } else if let script = BrowserRegistry.urlScript(for: browser),
                  let raw = scripting.frontTabURL(bundleID: browser.bundleID, script: script),
                  let normalized = BrowserRegistry.normalize(raw) {
            read = (normalized, .applescript)
        }
        guard let read else { return resolved }
        resolved.policySite = read.normalized.host.map { .host($0) } ?? .noHost
        if config.collectBrowserURL {
            resolved.urlSource = read.source
            resolved.browserURL = read.normalized.absolute
            resolved.urlHost = read.normalized.host
        }
        return resolved
    }

    /// The frontmost named window belonging to `pid`. `kCGWindowName` needs Screen Recording;
    /// without it the key is simply absent, which is a nil title, not an error.
    static func windowTitle(pid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return title(inWindowList: raw, pid: pid)
    }

    /// Pure half of `windowTitle(pid:)`, so the filtering rules can be tested against a fixture
    /// list instead of against whatever happens to be on screen.
    ///
    /// The list is front-to-back, so the first match is the focused window — but Chrome and
    /// friends keep unnamed layer-0 windows around, and returning nil at the first of those
    /// would throw away a title that is one entry further down.
    static func title(inWindowList windows: [[String: Any]], pid: pid_t) -> String? {
        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            let name = (window[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { return name }
        }
        return nil
    }
}

// MARK: - AppleScript

/// The one thing in the collector that can hang or prompt, behind a protocol so tests never do.
protocol BrowserURLScripting: Sendable {
    func frontTabURL(bundleID: String, script: String) -> String?
}

/// Runs a browser's URL AppleScript on a dedicated serial queue with a hard 1.5 s deadline.
///
/// Two failure modes matter. A browser that is beachballing would otherwise stall every capture
/// tick, so the deadline is absolute. And a denied Automation permission (error -1743) re-prompts
/// on every attempt, so a failing bundle is skipped for ten minutes — the user says no once, not
/// once a minute.
///
/// #64: that ten-minute silence used to be total — a whole day of browsing could produce no URL
/// at all and say so only at `debug`, which the file log never records. One `info` line opens
/// each backoff window now. Bundle id only: a failing probe has no URL and no title to leak, and
/// the reason the line is safe to keep at `info` is that it never gains one.
final class AppleScriptBrowserURL: BrowserURLScripting, @unchecked Sendable {
    static let timeout: TimeInterval = 1.5
    static let backoff: TimeInterval = 600

    /// The Apple event itself, behind a closure so a test can fail every attempt without
    /// sending one — `NSAppleScript` would prompt, or hang, on a machine running the tests.
    ///
    /// Returns the OSStatus alongside the URL, because "it failed" was not enough to explain
    /// #64: -1743 is a denial, -1744 is consent that was never asked for, and a nil code with no
    /// URL is a script that ran and had nothing to say. The number is the whole difference
    /// between "open Settings" and "this build can never work".
    typealias Runner = @Sendable (String) -> (url: String?, errorCode: Int?)

    private let queue = DispatchQueue(label: "dev.worklens.applescript")
    private let lock = NSLock()
    private var lastFailure: [String: Failure] = [:]
    private let run: Runner
    private let now: @Sendable () -> Date
    /// Where the once-per-window line goes. `Log.capture.info` in the app; a collector in tests,
    /// which is the only way to assert "one line per window" without reading the file log.
    private let logInfo: @Sendable (String) -> Void
    /// The TCC read that gates the probe (#117) and can cut a backoff window short (#79),
    /// behind a closure for the same reason `run` is: a test asserts what the window does
    /// without asking the system anything.
    private let automationStatus: @Sendable (String) -> AutomationPermission.Status

    init(
        run: @escaping Runner = AppleScriptBrowserURL.execute,
        now: @escaping @Sendable () -> Date = { Date() },
        logInfo: @escaping @Sendable (String) -> Void = { Log.capture.info($0) },
        automationStatus: @escaping @Sendable (String) -> AutomationPermission.Status = {
            AutomationPermission.status(forBundleID: $0)
        }
    ) {
        self.run = run
        self.now = now
        self.logInfo = logInfo
        self.automationStatus = automationStatus
    }

    private static let execute: Runner = { script in
        var error: NSDictionary?
        let output = NSAppleScript(source: script)?.executeAndReturnError(&error)
        // Only the number. `NSAppleScriptErrorMessage` is prose from the target application and
        // has no business at `info`.
        let code = error?[NSAppleScript.errorNumber] as? Int
        return error == nil ? (output?.stringValue, nil) : (nil, code)
    }

    func frontTabURL(bundleID: String, script: String) -> String? {
        // #117: only an allowed browser is ever probed. Before this guard a tick could send the
        // first Apple event to a browser nobody had been asked about, which raises the macOS
        // Automation dialog in the middle of whatever the user was doing — and then times out
        // after 1.5 s, so the answer is never recorded and the same dialog is due again. A
        // `.denied` browser is skipped for a duller reason: every attempt fails by construction.
        //
        // Nothing is recorded here — no failure, no backoff window. There is nothing to back off
        // from, and `AppModel.refreshBrowserURLs` is what turns "no URL and not allowed" into
        // the menu's offer to ask (`MenuState.browsersNotAsked`), which is the path that can
        // actually end in a decision (#79).
        guard automationStatus(bundleID) == .allowed else { return nil }
        if isBackedOff(bundleID) { return nil }

        // `result` is only touched under `semaphore`'s happens-before edge: written before
        // signal(), read after a successful wait(). The timeout path returns without reading it.
        nonisolated(unsafe) var result: (url: String?, errorCode: Int?) = (nil, nil)
        let semaphore = DispatchSemaphore(value: 0)
        let run = run
        queue.async {
            result = run(script)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + AppleScriptBrowserURL.timeout) == .success else {
            // A timeout leaves the work item running on the serial queue; the backoff is what
            // stops the next tick from queueing behind it and paying 1.5 s again.
            recordFailure(bundleID, reason: "no answer in \(AppleScriptBrowserURL.timeout) s")
            Log.capture.debug("browser URL unavailable for \(bundleID)")
            return nil
        }
        guard let url = result.url, !url.isEmpty else {
            recordFailure(
                bundleID,
                reason: result.errorCode.map { "AppleScript error \($0)" } ?? "empty answer"
            )
            Log.capture.debug("browser URL unavailable for \(bundleID)")
            return nil
        }
        return url
    }

    /// #79: the window also ends the moment the browser is allowed. Ten minutes of silence is
    /// right for a refusal — the point is not to re-prompt it — but wrong for a user who has
    /// just said yes and would otherwise watch the timeline say "Chrome" for ten more minutes.
    /// An allowed browser has no refusal left to re-provoke.
    ///
    /// The TCC read costs one lookup, happens only inside a window, and cannot prompt
    /// (`askUserIfNeeded: false`). It is taken outside the lock: nothing else touches
    /// `lastFailure` for this bundle in between, and holding a lock across a system call to
    /// spare an already-failing path is not a trade worth making.
    /// One failure, and whether the browser was already allowed when it happened. The second
    /// half is what tells a grant that has just landed apart from a browser that is allowed and
    /// simply not answering (#79).
    private struct Failure {
        let at: Date
        let wasAllowed: Bool
    }

    /// #79: a window that was opened by a *missing* grant ends the moment the grant arrives.
    /// Ten minutes of silence is right for a refusal — the point is not to re-prompt it — and
    /// wrong for a user who has just said yes and would otherwise watch the timeline say
    /// "Chrome" for ten more minutes.
    ///
    /// The transition is the test, not the status: a browser that was *already* allowed when the
    /// probe failed keeps its window, because that failure was a deadline or an empty answer and
    /// the backoff is the only thing stopping every tick from paying 1.5 s for the same silence.
    ///
    /// The TCC read costs one lookup, happens only inside a window opened without the grant, and
    /// cannot prompt (`askUserIfNeeded: false`). It is taken outside the lock: nothing else
    /// touches this bundle's entry in between, and holding a lock across a system call to spare
    /// an already-failing path is not a trade worth making.
    private func isBackedOff(_ bundleID: String) -> Bool {
        lock.lock()
        let failure = lastFailure[bundleID]
        lock.unlock()
        guard let failure else { return false }

        let expired = now().timeIntervalSince(failure.at) >= AppleScriptBrowserURL.backoff
        let granted = !failure.wasAllowed && automationStatus(bundleID) == .allowed
        guard expired || granted else { return true }
        lock.lock()
        lastFailure[bundleID] = nil
        lock.unlock()
        return false
    }

    /// Only ever reached when the bundle was *not* backed off, so this is the first failure of a
    /// window by construction and the line cannot repeat inside one.
    ///
    /// `reason` is a status number or a deadline, never anything the browser said.
    private func recordFailure(_ bundleID: String, reason: String) {
        // Read before the lock, and once per window rather than once per tick: this is only ever
        // reached on the failure that opens one.
        let failure = Failure(at: now(), wasAllowed: automationStatus(bundleID) == .allowed)
        lock.lock()
        lastFailure[bundleID] = failure
        lock.unlock()
        let minutes = Int(AppleScriptBrowserURL.backoff / 60)
        logInfo("browser URL probe failed for \(bundleID): \(reason); not retrying for \(minutes) min")
    }
}
