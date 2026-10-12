import CoreGraphics
import Foundation
import Testing
@testable import WorklensCore

@Suite("URL normalization")
struct URLNormalizationTests {
    private func normalize(_ raw: String?, storeQuery: Bool = false) -> BrowserRegistry.NormalizedURL? {
        BrowserRegistry.normalize(raw, storeQuery: storeQuery)
    }

    @Test("The query is dropped by default — it carries tokens and search terms")
    func dropsQuery() {
        let url = normalize("https://mail.google.com/mail/u/0?token=secret&q=layoffs")
        #expect(url?.absolute == "https://mail.google.com/mail/u/0")
        #expect(url?.host == "mail.google.com")
    }

    @Test("URL_STORE_QUERY=true keeps the query")
    func keepsQueryWhenAsked() {
        let url = normalize("https://example.com/search?q=swift", storeQuery: true)
        #expect(url?.absolute == "https://example.com/search?q=swift")
    }

    @Test("The fragment is always dropped, even with URL_STORE_QUERY on")
    func dropsFragment() {
        #expect(normalize("https://example.com/docs#section-3")?.absolute == "https://example.com/docs")
        #expect(normalize("https://example.com/a?b=c#frag", storeQuery: true)?.absolute
            == "https://example.com/a?b=c")
    }

    @Test("Scheme and host are lowercased, the path is left alone")
    func lowercasesHostNotPath() {
        let url = normalize("HTTPS://Example.COM/Path/To/Doc")
        #expect(url?.absolute == "https://example.com/Path/To/Doc")
        #expect(url?.host == "example.com")
    }

    @Test("A URL with no host still normalizes, with a nil host")
    func hostlessURL() {
        #expect(normalize("about:blank")?.host == nil)
        #expect(normalize("about:blank")?.absolute == "about:blank")
    }

    @Test("Empty, blank and unparseable input yields nil")
    func rejectsJunk() {
        #expect(normalize(nil) == nil)
        #expect(normalize("") == nil)
        #expect(normalize("   ") == nil)
    }
}

@Suite("Browser title suffixes")
struct BrowserTitleTests {
    @Test("Firefox titles lose the browser name, since the title is all Firefox gives us")
    func firefox() {
        let stripped = BrowserRegistry.strippedTitle(
            "Swift Testing — Mozilla Firefox", bundleID: "org.mozilla.firefox"
        )
        #expect(stripped == "Swift Testing")
    }

    @Test("Chromium-family suffixes")
    func chromiumFamily() {
        #expect(BrowserRegistry.strippedTitle("Inbox - Google Chrome", bundleID: "com.google.Chrome")
            == "Inbox")
        #expect(BrowserRegistry.strippedTitle("Docs - Brave", bundleID: "com.brave.Browser") == "Docs")
        #expect(BrowserRegistry.strippedTitle("Portal - Microsoft Edge", bundleID: "com.microsoft.edgemac")
            == "Portal")
        #expect(BrowserRegistry.strippedTitle("Notes — Arc", bundleID: "company.thebrowser.Browser")
            == "Notes")
    }

    @Test("A title without the suffix, and a non-browser app, are untouched")
    func leavesOthersAlone() {
        #expect(BrowserRegistry.strippedTitle("Inbox", bundleID: "com.google.Chrome") == "Inbox")
        #expect(BrowserRegistry.strippedTitle("Inbox - Google Chrome", bundleID: "com.tinyspeck.slackmacgap")
            == "Inbox - Google Chrome")
        #expect(BrowserRegistry.strippedTitle(nil, bundleID: "com.google.Chrome") == nil)
    }

    @Test("A Chrome profile after the browser name goes too — AXTitle carries both (#55)")
    func chromeProfileSuffix() {
        // What `AXTitle` reports for a Chrome with more than one profile, where `kCGWindowName`
        // reports only "Deal Radar · Riverbend Capital". Both readers must land on the same title,
        // and the profile — a person's name — must not end up on every row.
        #expect(BrowserRegistry.strippedTitle(
            "Deal Radar · Riverbend Capital - Google Chrome - Alex (Your Chrome)",
            bundleID: "com.google.Chrome"
        ) == "Deal Radar · Riverbend Capital")
        #expect(BrowserRegistry.strippedTitle(
            "Inbox (12) - Google Chrome Canary - Work", bundleID: "com.google.Chrome.canary"
        ) == "Inbox (12)")
        #expect(BrowserRegistry.strippedTitle(
            "Docs - Brave Browser - Profile 2", bundleID: "com.brave.Browser"
        ) == "Docs")
    }

    @Test("A page whose own title names the browser keeps as much of itself as it can")
    func titleContainingTheBrowserName() {
        #expect(BrowserRegistry.strippedTitle(
            "Why - Google Chrome eats RAM - Google Chrome", bundleID: "com.google.Chrome"
        ) == "Why - Google Chrome eats RAM")
    }

    @Test("A title that is only the suffix collapses to nil rather than an empty string")
    func suffixOnly() {
        #expect(BrowserRegistry.strippedTitle(" - Google Chrome", bundleID: "com.google.Chrome") == nil)
    }

    @Test("Only Firefox lacks a URL script; the rest have one")
    func urlScripts() {
        let firefox = BrowserRegistry.browser(forBundleID: "org.mozilla.firefox")!
        #expect(BrowserRegistry.urlScript(for: firefox) == nil)

        let safari = BrowserRegistry.browser(forBundleID: "com.apple.Safari")!
        #expect(BrowserRegistry.urlScript(for: safari)?.contains("front document") == true)

        let chrome = BrowserRegistry.browser(forBundleID: "com.google.Chrome")!
        #expect(BrowserRegistry.urlScript(for: chrome)?.contains("active tab of front window") == true)

        #expect(BrowserRegistry.isBrowser("com.tinyspeck.slackmacgap") == false)
        #expect(BrowserRegistry.isBrowser(nil) == false)
    }
}

@Suite("ForegroundContext signature")
struct ForegroundContextSignatureTests {
    private func context(
        bundle: String? = "com.google.Chrome", title: String? = "Inbox", url: String? = nil
    ) -> ForegroundContext {
        ForegroundContext(bundleID: bundle, appName: "App", pid: 1, windowTitle: title, browserURL: url)
    }

    @Test("Time passing and a relaunch (new pid) do not change the signature")
    func stableAcrossPidAndTime() {
        var a = context()
        var b = context()
        b.pid = 99
        b.collectedAt = a.collectedAt.addingTimeInterval(3600)
        #expect(a.signature == b.signature)
        a.appName = "Renamed"
        #expect(a.signature == b.signature)
    }

    @Test("App, title and page each change the signature")
    func changesOnRealChanges() {
        let base = context(url: "https://example.com/a")
        #expect(base.signature != context(bundle: "com.apple.Safari", url: "https://example.com/a").signature)
        #expect(base.signature != context(title: "Sent", url: "https://example.com/a").signature)
        #expect(base.signature != context(url: "https://example.com/b").signature)
    }

    @Test("Only host and path count, so a kept query does not churn the signature")
    func ignoresSchemeAndQuery() {
        let withQuery = context(url: "https://Example.com/a?page=2")
        let without = context(url: "https://example.com/a")
        #expect(withQuery.signature == without.signature)
    }

    @Test("A missing app or title still produces a comparable signature")
    func handlesNils() {
        let empty = ForegroundContext(appName: "unknown")
        #expect(empty.signature == "-|-|-")
        #expect(empty.signature == ForegroundContext(appName: "unknown").signature)
    }
}

// MARK: - Collector wiring

/// Stands in for the AppleScript round trip so tests never prompt for Automation.
private struct StubScripting: BrowserURLScripting {
    let url: String?
    func frontTabURL(bundleID: String, script: String) -> String? { url }
}

@Suite("Collector URL wiring")
struct CollectorURLTests {
    private func config(collect: Bool = true) -> Config {
        var config = Config.defaults()
        config.collectBrowserURL = collect
        return config
    }

    // These run against the real frontmost app, which is whatever the developer happens to have
    // in front — so they assert the *rule* rather than a particular app's outcome.

    @Test("COLLECT_BROWSER_URL=false means no URL, whatever is in front")
    func respectsOptOut() {
        let collector = ForegroundContextCollector(
            config: config(collect: false), scripting: StubScripting(url: "https://example.com/x?a=1")
        )
        let context = collector.collect()
        #expect(context.browserURL == nil)
        #expect(context.urlHost == nil)
    }

    @Test("A URL appears only for a known browser, and only after normalization")
    func urlOnlyForBrowsers() {
        let collector = ForegroundContextCollector(
            config: config(), scripting: StubScripting(url: "https://Example.com/x?a=1#f")
        )
        let context = collector.collect()
        if BrowserRegistry.isBrowser(context.bundleID) {
            // Firefox has no URL script, so the stub is never consulted for it.
            if BrowserRegistry.browser(forBundleID: context.bundleID)?.urlSource == .titleOnly {
                #expect(context.browserURL == nil)
            } else {
                #expect(context.browserURL == "https://example.com/x")
                #expect(context.urlHost == "example.com")
            }
        } else {
            #expect(context.browserURL == nil)
            #expect(context.urlHost == nil)
        }
    }
}

@Suite("Window title selection")
struct WindowTitleTests {
    private func window(
        pid: pid_t, layer: Int = 0, alpha: Double = 1, name: String? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
        ]
        if let name { entry[kCGWindowName as String] = name }
        return entry
    }

    @Test("Takes the frontmost layer-0 window of the right process")
    func frontmostWindow() {
        let list = [
            window(pid: 2, name: "Someone else"),
            window(pid: 1, name: "Inbox"),
            window(pid: 1, name: "Behind"),
        ]
        #expect(ForegroundContextCollector.title(inWindowList: list, pid: 1) == "Inbox")
    }

    @Test("Skips unnamed layer-0 windows rather than giving up — Chrome keeps several")
    func skipsUnnamedWindows() {
        let list = [window(pid: 1), window(pid: 1, name: "  "), window(pid: 1, name: "Docs")]
        #expect(ForegroundContextCollector.title(inWindowList: list, pid: 1) == "Docs")
    }

    @Test("Ignores menu-bar/overlay layers and fully transparent windows")
    func ignoresNonNormalWindows() {
        let list = [
            window(pid: 1, layer: 25, name: "Status item"),
            window(pid: 1, alpha: 0, name: "Invisible"),
            window(pid: 1, name: "Real window"),
        ]
        #expect(ForegroundContextCollector.title(inWindowList: list, pid: 1) == "Real window")
    }

    @Test("No permission means no kCGWindowName at all, which is nil and not an error")
    func missingNamesYieldNil() {
        #expect(ForegroundContextCollector.title(inWindowList: [window(pid: 1)], pid: 1) == nil)
        #expect(ForegroundContextCollector.title(inWindowList: [], pid: 1) == nil)
    }
}

// MARK: - The accessibility header (#55)

/// Counts whether the AppleScript probe was consulted at all. The point of the header is that a
/// granted Accessibility permission costs no Apple Events prompt, so "was it asked?" is the
/// assertion, not just "what did it answer?".
private final class CountingScripting: BrowserURLScripting, @unchecked Sendable {
    let url: String?
    private(set) var calls = 0

    init(url: String?) { self.url = url }

    func frontTabURL(bundleID: String, script: String) -> String? {
        calls += 1
        return url
    }
}

/// The `kCGWindowName` half, as a closure that says whether it was needed. With an accessibility
/// title there is no reason to pay for `CGWindowListCopyWindowInfo` at all.
private final class CountingWindowList: @unchecked Sendable {
    let title: String?
    private(set) var calls = 0

    init(title: String?) { self.title = title }

    func read() -> String? {
        calls += 1
        return title
    }
}

@Suite("Collector metadata sources")
struct ForegroundContextSourceTests {
    private struct Outcome {
        let resolved: ForegroundContextCollector.Resolved
        let probeCalls: Int
        let windowListCalls: Int
    }

    /// The precedence in isolation: no desktop, no permissions, no frontmost app.
    private func resolve(
        bundleID: String? = "com.google.Chrome",
        header: AXHeader?,
        windowList: String? = nil,
        probe: String? = nil,
        collectBrowserURL: Bool = true
    ) -> Outcome {
        var config = Config.defaults()
        config.collectBrowserURL = collectBrowserURL
        let scripting = CountingScripting(url: probe)
        let list = CountingWindowList(title: windowList)
        let resolved = ForegroundContextCollector.resolve(
            bundleID: bundleID,
            header: header,
            windowListTitle: { list.read() },
            config: config,
            scripting: scripting
        )
        return Outcome(resolved: resolved, probeCalls: scripting.calls, windowListCalls: list.calls)
    }

    @Test("A header with both attributes answers both, and neither probe is consulted")
    func headerPresent() {
        let outcome = resolve(
            header: AXHeader(
                pid: 7, windowTitle: "Inbox (12) - Google Chrome",
                webURL: "https://Mail.Google.com/mail/u/0?token=secret#inbox"
            ),
            windowList: "Should not be needed",
            probe: "https://example.com/should-not-be-asked"
        )
        #expect(outcome.resolved.windowTitle == "Inbox (12)")
        #expect(outcome.resolved.titleSource == .ax)
        #expect(outcome.resolved.browserURL == "https://mail.google.com/mail/u/0")
        #expect(outcome.resolved.urlHost == "mail.google.com")
        #expect(outcome.resolved.urlSource == .ax)
        #expect(outcome.probeCalls == 0)
        #expect(outcome.windowListCalls == 0)
    }

    @Test("No header — Accessibility denied — is today's window list and today's probe")
    func headerAbsent() {
        let outcome = resolve(
            header: nil,
            windowList: "Inbox (12) - Google Chrome",
            probe: "https://mail.google.com/mail/u/0"
        )
        #expect(outcome.resolved.windowTitle == "Inbox (12)")
        #expect(outcome.resolved.titleSource == .windowList)
        #expect(outcome.resolved.browserURL == "https://mail.google.com/mail/u/0")
        #expect(outcome.resolved.urlSource == .applescript)
        #expect(outcome.probeCalls == 1)
        #expect(outcome.windowListCalls == 1)
    }

    @Test("A partial header — a title but no URL — keeps the AppleScript probe underneath")
    func partialHeaderTitleOnly() {
        let outcome = resolve(
            header: AXHeader(pid: 7, windowTitle: "Docs - Google Chrome"),
            windowList: "Should not be needed",
            probe: "https://docs.example.com/plan"
        )
        #expect(outcome.resolved.windowTitle == "Docs")
        #expect(outcome.resolved.titleSource == .ax)
        #expect(outcome.resolved.browserURL == "https://docs.example.com/plan")
        #expect(outcome.resolved.urlSource == .applescript)
        #expect(outcome.windowListCalls == 0)
    }

    @Test("A partial header — a URL but no title — keeps kCGWindowName underneath")
    func partialHeaderURLOnly() {
        let outcome = resolve(
            header: AXHeader(pid: 7, webURL: "https://docs.example.com/plan"),
            windowList: "Plan - Google Chrome",
            probe: "https://example.com/should-not-be-asked"
        )
        #expect(outcome.resolved.windowTitle == "Plan")
        #expect(outcome.resolved.titleSource == .windowList)
        #expect(outcome.resolved.urlSource == .ax)
        #expect(outcome.probeCalls == 0)
    }

    @Test("A blank header attribute is a missing one, not an empty title")
    func blankAttributesFallBack() {
        let outcome = resolve(
            header: AXHeader(pid: 7, windowTitle: "   ", webURL: "  "),
            windowList: "Real title",
            probe: "https://example.com/page"
        )
        #expect(outcome.resolved.windowTitle == "Real title")
        #expect(outcome.resolved.titleSource == .windowList)
        #expect(outcome.resolved.urlSource == .applescript)
    }

    @Test("Firefox gets a URL and a host from the header — no AppleScript ever could")
    func firefoxGetsAURL() {
        let withHeader = resolve(
            bundleID: "org.mozilla.firefox",
            header: AXHeader(
                pid: 7, windowTitle: "Swift Testing — Mozilla Firefox",
                webURL: "https://swift.org/documentation/testing/"
            ),
            probe: "https://example.com/never-asked"
        )
        #expect(withHeader.resolved.windowTitle == "Swift Testing")
        #expect(withHeader.resolved.browserURL == "https://swift.org/documentation/testing/")
        #expect(withHeader.resolved.urlHost == "swift.org")
        #expect(withHeader.resolved.urlSource == .ax)
        #expect(withHeader.probeCalls == 0)

        // Today, and still the outcome without the grant: Firefox has no URL script, so the stub
        // is never consulted for it.
        let withoutHeader = resolve(
            bundleID: "org.mozilla.firefox",
            header: nil,
            windowList: "Swift Testing — Mozilla Firefox",
            probe: "https://swift.org/documentation/testing/"
        )
        #expect(withoutHeader.resolved.browserURL == nil)
        #expect(withoutHeader.resolved.urlHost == nil)
        #expect(withoutHeader.resolved.urlSource == .none)
        #expect(withoutHeader.probeCalls == 0)
    }

    @Test("Screen Recording denied still leaves a window title, from the tree")
    func titleWithoutScreenRecording() {
        // Without Screen Recording `kCGWindowName` is simply absent, which is a nil title.
        let outcome = resolve(
            bundleID: "com.tinyspeck.slackmacgap",
            header: AXHeader(pid: 7, windowTitle: "#engineering — Acme"),
            windowList: nil
        )
        #expect(outcome.resolved.windowTitle == "#engineering — Acme")
        #expect(outcome.resolved.titleSource == .ax)
    }

    @Test("Neither reader having anything is `none`, not an empty string")
    func nothingAtAll() {
        let outcome = resolve(bundleID: "com.apple.dt.Xcode", header: AXHeader(pid: 7))
        #expect(outcome.resolved.windowTitle == nil)
        #expect(outcome.resolved.titleSource == .none)
        #expect(outcome.resolved.urlSource == .none)
    }

    @Test("COLLECT_BROWSER_URL=false drops the URL whatever the header says")
    func respectsOptOutWithHeader() {
        let outcome = resolve(
            header: AXHeader(pid: 7, windowTitle: "Inbox", webURL: "https://mail.google.com/mail/u/0"),
            collectBrowserURL: false
        )
        #expect(outcome.resolved.windowTitle == "Inbox")
        #expect(outcome.resolved.browserURL == nil)
        #expect(outcome.resolved.urlHost == nil)
        #expect(outcome.resolved.urlSource == .none)
        #expect(outcome.probeCalls == 0)
    }

    @Test("A header URL on an app that is not a known browser is not a browser URL")
    func nonBrowserHeaderURL() {
        let outcome = resolve(
            bundleID: "com.apple.Preview",
            header: AXHeader(
                pid: 7, windowTitle: "plan.pdf",
                documentURL: "https://files.example.com/plan.pdf",
                webURL: "https://files.example.com/plan.pdf"
            )
        )
        #expect(outcome.resolved.windowTitle == "plan.pdf")
        #expect(outcome.resolved.browserURL == nil)
        #expect(outcome.resolved.urlSource == .none)
    }

    @Test("The two readers normalise identically — URL_STORE_QUERY and the host are unchanged")
    func normalisationParity() {
        let raws = [
            "https://Mail.Google.com/mail/u/0?token=secret#inbox",
            "https://example.com/search?q=swift",
            "HTTPS://Example.COM/Path/To/Doc",
            "about:blank",
            "file:///Users/someone/notes.md",
            "https://example.com",
        ]
        for raw in raws {
            let viaHeader = resolve(header: AXHeader(pid: 7, webURL: raw)).resolved
            let viaProbe = resolve(header: nil, probe: raw).resolved
            #expect(viaHeader.browserURL == viaProbe.browserURL, "\(raw)")
            #expect(viaHeader.urlHost == viaProbe.urlHost, "\(raw)")
            // Same value, different provenance — which is the only thing that differs.
            #expect(viaHeader.urlSource == (viaHeader.browserURL == nil ? .none : .ax))
            #expect(viaProbe.urlSource == (viaProbe.browserURL == nil ? .none : .applescript))
        }
    }
}

/// A snapshotter that only has a header to offer, which is all the collector asks of one.
private final class StubHeaders: AXHeaderProviding, @unchecked Sendable {
    private let header: AXHeader?
    private(set) var pids: [pid_t] = []

    init(_ header: AXHeader?) { self.header = header }

    func header(pid: pid_t) -> AXHeader? {
        pids.append(pid)
        return header
    }
}

@Suite("Collector header wiring")
struct ForegroundContextHeaderWiringTests {
    /// Runs against the real frontmost app, like the other collector tests, so it asserts the
    /// wiring — which pid was asked, and whose answer won — rather than a particular app.
    @Test("The header is asked for the frontmost pid, and its title wins")
    func consultsTheHeader() {
        let headers = StubHeaders(AXHeader(pid: 0, windowTitle: "From the tree"))
        let collector = ForegroundContextCollector(
            config: Config.defaults(), scripting: StubScripting(url: nil), headers: headers
        )
        let reading = collector.collectWithHeader()
        #expect(headers.pids == [reading.context.pid])
        #expect(reading.context.windowTitle == "From the tree")
        #expect(reading.context.titleSource == .ax)
        // The elements the walk would reuse travel with the reading, not with the context.
        #expect(reading.header?.windowTitle == "From the tree")
        // `collect()` is the same read without the elements, so it must agree about the title.
        #expect(collector.collect().windowTitle == "From the tree")
    }

    @Test("No header provider at all is the pre-#55 collector, sources and all")
    func withoutAProvider() {
        let collector = ForegroundContextCollector(
            config: Config.defaults(), scripting: StubScripting(url: nil)
        )
        let reading = collector.collectWithHeader()
        #expect(reading.header == nil)
        #expect(reading.context.titleSource != .ax)
        #expect(reading.context.urlSource != .ax)
    }
}

// MARK: - The probe's one visible line (#64)

/// Collects what `AppleScriptBrowserURL` would have written to the file log, so "one line per
/// backoff window" is an assertion rather than something you read a log to find out.
private final class LogSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

@Suite("AppleScript probe failures are visible")
struct AppleScriptBrowserURLLoggingTests {
    private func probe(clock: @escaping @Sendable () -> Date, spy: LogSpy) -> AppleScriptBrowserURL {
        // The runner is the failing fake: no Apple event leaves the test process. The status is
        // stubbed `.allowed`, because the real read would answer for whatever browsers the
        // machine running the tests happens to have granted (#79) — and because since #117 only
        // an allowed browser is probed at all, so an allowed one that will not answer is exactly
        // what the backoff is still for.
        AppleScriptBrowserURL(
            // -1743 is errAEEventNotPermitted: the number the log prints, and the difference
            // between "open Settings" and "this build can never work".
            run: { _ in (nil, -1743) }, now: clock, logInfo: { spy.append($0) },
            automationStatus: { _ in .allowed }
        )
    }

    @Test("A failing probe says so once per ten-minute window, and names only the bundle")
    func oncePerWindow() {
        let start = Date(timeIntervalSince1970: 1_757_000_000)
        nonisolated(unsafe) var now = start
        let spy = LogSpy()
        let probe = probe(clock: { now }, spy: spy)
        let script = "tell application id \"com.google.Chrome\" to get URL"

        for _ in 0..<5 {
            #expect(probe.frontTabURL(bundleID: "com.google.Chrome", script: script) == nil)
            now = now.addingTimeInterval(60)
        }
        #expect(spy.all.count == 1)
        #expect(spy.all[0].contains("com.google.Chrome"))
        // The status number is the point: -1743 is a denial and -1744 is consent never asked
        // for, and only the number tells the user which of the two they are looking at.
        #expect(spy.all[0].contains("-1743"))
        // Bundle id and a number: nothing that could carry a page title or a URL.
        #expect(!spy.all[0].contains("http"))

        // Past the backoff the window reopens, and the next failure opens it out loud.
        now = start.addingTimeInterval(AppleScriptBrowserURL.backoff + 1)
        #expect(probe.frontTabURL(bundleID: "com.google.Chrome", script: script) == nil)
        #expect(spy.all.count == 2)
    }

    @Test("Each browser gets its own window — one failing browser does not silence another")
    func perBundle() {
        nonisolated(unsafe) let now = Date(timeIntervalSince1970: 1_757_000_000)
        let spy = LogSpy()
        let probe = probe(clock: { now }, spy: spy)
        #expect(probe.frontTabURL(bundleID: "com.google.Chrome", script: "x") == nil)
        #expect(probe.frontTabURL(bundleID: "com.apple.Safari", script: "y") == nil)
        #expect(probe.frontTabURL(bundleID: "com.google.Chrome", script: "x") == nil)
        #expect(spy.all.count == 2)
    }

    @Test("#117: a browser that is not allowed is never probed, and nothing is logged")
    func notAllowedIsNeverProbed() {
        for status in [AutomationPermission.Status.notAsked, .denied, .notRunning] {
            let spy = LogSpy()
            // A runner that would fail the test if it ran: before #117 a tick sent this browser
            // its first Apple event, which raised the macOS Automation dialog in the middle of
            // whatever the user was doing and then timed out without recording an answer.
            nonisolated(unsafe) var probed = false
            let probe = AppleScriptBrowserURL(
                run: { _ in probed = true; return (nil, -1744) },
                logInfo: { spy.append($0) },
                automationStatus: { _ in status }
            )
            #expect(probe.frontTabURL(bundleID: "com.google.Chrome", script: "x") == nil)
            #expect(!probed)
            // Nothing recorded either: there is no failure to back off from.
            #expect(spy.all.isEmpty)
        }
    }

    @Test("A probe that answers logs nothing")
    func successIsSilent() {
        let spy = LogSpy()
        let probe = AppleScriptBrowserURL(
            run: { _ in ("https://example.com/", nil) }, logInfo: { spy.append($0) },
            automationStatus: { _ in .allowed }
        )
        #expect(probe.frontTabURL(bundleID: "com.google.Chrome", script: "x") == "https://example.com/")
        #expect(spy.all.isEmpty)
    }
}

// MARK: - The backoff ends when the grant lands (#79)

@Suite("A granted browser does not sit out its backoff")
struct AppleScriptBackoffTests {
    /// Fails until `answer` is given one, so a single probe can play "denied, then allowed".
    private final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var _url: String?
        private var _status: AutomationPermission.Status = .notAsked
        private var _statusReads = 0

        var url: String? {
            get { lock.lock(); defer { lock.unlock() }; return _url }
            set { lock.lock(); _url = newValue; lock.unlock() }
        }
        var status: AutomationPermission.Status {
            get { lock.lock(); defer { lock.unlock() }; return _status }
            set { lock.lock(); _status = newValue; lock.unlock() }
        }
        var statusReads: Int {
            lock.lock(); defer { lock.unlock() }; return _statusReads
        }
        func readStatus() -> AutomationPermission.Status {
            lock.lock(); defer { lock.unlock() }
            _statusReads += 1
            return _status
        }
    }

    private func probe(_ fake: Fake, now: @escaping @Sendable () -> Date) -> AppleScriptBrowserURL {
        AppleScriptBrowserURL(
            run: { _ in fake.url.map { ($0, nil) } ?? (nil, -1744) },
            now: now,
            logInfo: { _ in },
            automationStatus: { _ in fake.readStatus() }
        )
    }

    @Test("Granting gets the URL on the next tick, not ten minutes later")
    func grantEndsTheWindow() {
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_757_000_000)
        let fake = Fake()
        let probe = probe(fake, now: { now })

        // Never asked: since #117 the probe is skipped outright rather than sending the Apple
        // event that used to raise the dialog and then time out. Either way, no URL.
        #expect(probe.frontTabURL(bundleID: "com.apple.Safari", script: "x") == nil)
        now = now.addingTimeInterval(60)
        #expect(probe.frontTabURL(bundleID: "com.apple.Safari", script: "x") == nil)

        // The user clicks Ask… and allows it. The promise #79 made is the one that matters here
        // and it still holds: the very next tick reads the URL, with nothing to wait out.
        fake.status = .allowed
        fake.url = "https://example.com/"
        now = now.addingTimeInterval(60)
        #expect(probe.frontTabURL(bundleID: "com.apple.Safari", script: "x") == "https://example.com/")
    }

    @Test("An allowed browser that simply will not answer keeps its window")
    func allowedFailureStillBacksOff() {
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_757_000_000)
        let fake = Fake()
        fake.status = .allowed
        let probe = probe(fake, now: { now })

        // A beachballing browser: allowed, and answering nothing. The window is the only thing
        // stopping every tick from paying the 1.5 s deadline again.
        #expect(probe.frontTabURL(bundleID: "com.apple.Safari", script: "x") == nil)
        fake.url = "https://example.com/"
        now = now.addingTimeInterval(60)
        #expect(probe.frontTabURL(bundleID: "com.apple.Safari", script: "x") == nil)

        // The window still ends on its own schedule.
        now = now.addingTimeInterval(AppleScriptBrowserURL.backoff)
        #expect(probe.frontTabURL(bundleID: "com.apple.Safari", script: "x") == "https://example.com/")
    }

    @Test("TCC is read once to let a tick through, and once more only when it fails")
    func statusIsReadSparingly() {
        nonisolated(unsafe) let now = Date(timeIntervalSince1970: 1_757_000_000)
        let fake = Fake()
        fake.status = .allowed
        fake.url = "https://example.com/"
        let probe = probe(fake, now: { now })

        // #117 pays one lookup per tick for the gate. It is a local TCC read that cannot prompt,
        // which is the price of never putting a consent dialog in front of somebody mid-sentence.
        for _ in 0..<3 {
            #expect(probe.frontTabURL(bundleID: "com.apple.Safari", script: "x") == "https://example.com/")
        }
        #expect(fake.statusReads == 3)

        // A failure costs a second read, to record whether the browser was allowed when the
        // window opened. The backed-off tick after it is back to one: the gate, and no more,
        // because a window opened by an allowed browser has no grant left to wait for.
        fake.url = nil
        #expect(probe.frontTabURL(bundleID: "com.apple.Safari", script: "x") == nil)
        #expect(fake.statusReads == 5)
        #expect(probe.frontTabURL(bundleID: "com.apple.Safari", script: "x") == nil)
        #expect(fake.statusReads == 6)
    }
}
