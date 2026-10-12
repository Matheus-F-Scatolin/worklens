import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - The snapshot

/// What one application's focused window exposes to assistive technology, flattened into a
/// deterministic outline with a grade for how much of the window it covers (#50, #52).
public struct AXSnapshot: Sendable, Equatable {
    /// How much of the window the walk actually got.
    public enum Coverage: String, Codable, Sendable, Equatable, CaseIterable {
        /// The walk finished *and* produced at least `AX_MIN_TEXT_CHARS`. #53 trusts the text
        /// hash on its own for these.
        case full
        /// Some text, but the budget or the deadline stopped the walk, or it came in under the
        /// minimum. Electron apps are allowed to land here.
        case partial
        /// No window, the API refused (`kAXErrorAPIDisabled` / `kAXErrorCannotComplete`), or one
        /// node and nothing else — a game, a VM, a canvas.
        case none

        /// The one place the grade is decided, so #53 and the tests agree with the CLI.
        public static func classify(
            nodes: Int, textChars: Int, finished: Bool, minChars: Int
        ) -> Coverage {
            guard nodes > 1, textChars > 0 else { return .none }
            return finished && textChars >= minChars ? .full : .partial
        }
    }

    public var windowTitle: String?
    /// `AXDocument` — the file the window is editing, as a URL string.
    public var documentURL: String?
    /// The `AXWebArea`'s `AXURL`. #55 consumes this instead of the AppleScript browser bridge.
    public var webURL: String?
    public var focused: AXNode?
    public var nodes: [AXNode]
    /// The rendered outline. Redacted before it is stored or sent — never by this type (#49, #53).
    public var text: String
    public var textHash: String
    public var coverage: Coverage
    public var elapsedMs: Int
    /// Set on Electron apps before walking; side-effect-free, no reset needed.
    public var didSetManualAccessibility: Bool
    /// Set only when the tree was still empty afterwards. Known to change window-resize behaviour
    /// in some Chromium builds, so #53 resets it when the app stops being frontmost — which is
    /// why the snapshot has to say it happened.
    public var didSetEnhancedUserInterface: Bool

    public var nodeCount: Int { nodes.count }

    public init(
        windowTitle: String? = nil,
        documentURL: String? = nil,
        webURL: String? = nil,
        focused: AXNode? = nil,
        nodes: [AXNode] = [],
        text: String = "",
        textHash: String = AXOutline.hash(""),
        coverage: Coverage = .none,
        elapsedMs: Int = 0,
        didSetManualAccessibility: Bool = false,
        didSetEnhancedUserInterface: Bool = false
    ) {
        self.windowTitle = windowTitle
        self.documentURL = documentURL
        self.webURL = webURL
        self.focused = focused
        self.nodes = nodes
        self.text = text
        self.textHash = textHash
        self.coverage = coverage
        self.elapsedMs = elapsedMs
        self.didSetManualAccessibility = didSetManualAccessibility
        self.didSetEnhancedUserInterface = didSetEnhancedUserInterface
    }
}

// MARK: - The header

/// What the focused window says about *itself*, before anything walks it (#55): its title, the
/// document it is editing and the page it is showing.
///
/// Deliberately cheap — one multi-attribute read of the window element plus `AXDocument`, and no
/// walk — because `ForegroundContextCollector` needs a title and a URL **before** the privacy
/// blocklist decides whether the tree may be read at all. It also carries the window and focused
/// elements it had to resolve anyway, so the walk that follows the blocklist reuses them instead
/// of creating a second application element and looking the focused window up again.
public struct AXHeader: @unchecked Sendable {
    /// The process the elements below belong to. `snapshot(pid:header:)` reuses them only for
    /// this pid: the frontmost app can change between the header and the walk.
    public let pid: pid_t
    public var windowTitle: String?
    /// `AXDocument` — the file (or, for a browser window, the page) the window is editing.
    public var documentURL: String?
    /// The page the window is showing, from `AXURL` on the window, from the focused element when
    /// that *is* the web area, or from `documentURL` when it is an http(s) URL — which is how a
    /// Chromium window names its tab. `nil` for everything that is not a web page.
    public var webURL: String?

    /// Resolved once and memoised. `@unchecked Sendable` covers these two: an `AXUIElement` is a
    /// CF object that may be messaged from any thread, and the only thread that ever messages
    /// these is the snapshotter's own detached task.
    let window: (any AXElementSource)?
    let focused: (any AXElementSource)?

    /// The value half, for callers (and fakes) that have no elements to hand over.
    public init(
        pid: pid_t = 0, windowTitle: String? = nil, documentURL: String? = nil, webURL: String? = nil
    ) {
        self.init(
            pid: pid, windowTitle: windowTitle, documentURL: documentURL, webURL: webURL,
            window: nil, focused: nil
        )
    }

    init(
        pid: pid_t,
        windowTitle: String?,
        documentURL: String?,
        webURL: String?,
        window: (any AXElementSource)?,
        focused: (any AXElementSource)?
    ) {
        self.pid = pid
        self.windowTitle = windowTitle
        self.documentURL = documentURL
        self.webURL = webURL
        self.window = window
        self.focused = focused
    }

    /// The header's decisions, over the element seam rather than over `AXUIElement`, so the
    /// fixture tree drives them and the round-trip count can be asserted.
    ///
    /// `documentURL` comes in as a value because `AXDocument` is not one of the attributes
    /// `AXElementRead` carries — it is the header's one extra read.
    static func make(
        pid: pid_t,
        window: any AXElementSource,
        focused: (any AXElementSource)?,
        documentURL: String?
    ) -> AXHeader {
        let read = window.read()
        let document = documentURL?.nonEmpty
        var webURL = read.url?.nonEmpty
        if webURL == nil, let focused, focused.read().role == AXRoles.webArea {
            // Only when the focused element *is* the web area: the `AXURL` of anything inside one
            // is a link's href, which is a page the user is not on.
            webURL = focused.read().url?.nonEmpty
        }
        if webURL == nil, let document, document.lowercased().hasPrefix("http") { webURL = document }
        return AXHeader(
            pid: pid,
            windowTitle: read.title?.nonEmpty,
            documentURL: document,
            webURL: webURL,
            window: window,
            focused: focused
        )
    }
}

/// The one thing `ForegroundContextCollector` needs from the snapshotter (#55): the cheap header,
/// never the walk. A separate protocol so the collector's tests hand it a fake header without
/// standing up a whole snapshotter.
public protocol AXHeaderProviding: Sendable {
    /// Blocking, and meant to be: it is two accessibility round-trips under the walk's messaging
    /// timeout, called from the same place that used to pay for `CGWindowListCopyWindowInfo` and
    /// an AppleScript. `nil` when this process is not trusted for Accessibility.
    func header(pid: pid_t) -> AXHeader?
}

public protocol AccessibilitySnapshotting: AXHeaderProviding, Sendable {
    /// `nil` only when this process is not trusted for Accessibility. Everything else — no window,
    /// a frozen app, a canvas that exposes nothing — comes back as a snapshot with `.none`, so a
    /// caller can tell "not allowed to look" from "looked and there was nothing".
    func snapshot(pid: pid_t) async -> AXSnapshot?

    /// The same walk, reusing the window and focused element `header` already resolved for this
    /// pid (#55), so one tick costs one `AXUIElementCreateApplication` and one focused-window
    /// lookup rather than two of each.
    func snapshot(pid: pid_t, header: AXHeader?) async -> AXSnapshot?

    /// Turns `AXEnhancedUserInterface` back off on an application the snapshotter had switched it
    /// on for. Called by `CaptureScheduler` when that app stops being frontmost (#53): the switch
    /// changes window-resize behaviour in some Chromium builds, so it must not outlive the walk
    /// that needed it. A no-op for anything that never set it.
    func resetEnhancedUserInterface(pid: pid_t) async
}

public extension AccessibilitySnapshotting {
    /// Default for a snapshotter that never touches the switch — every fake, and any future
    /// implementation reading a fixture tree.
    func resetEnhancedUserInterface(pid: pid_t) async {}

    /// Default for a snapshotter with no cheap header to offer: the collector then falls back to
    /// `kCGWindowName` and the AppleScript probe, exactly as before #55.
    func header(pid: pid_t) -> AXHeader? { nil }

    /// Default for a snapshotter that cannot reuse elements — every fake, and any implementation
    /// whose tree does not come from `AXUIElement`.
    func snapshot(pid: pid_t, header: AXHeader?) async -> AXSnapshot? { await snapshot(pid: pid) }
}

// MARK: - The live implementation

public struct AccessibilitySnapshotter: AccessibilitySnapshotting {
    private let limits: AXWalkLimits

    public init(limits: AXWalkLimits = AXWalkLimits()) {
        self.limits = limits
    }

    public func snapshot(pid: pid_t) async -> AXSnapshot? {
        await snapshot(pid: pid, header: nil)
    }

    public func snapshot(pid: pid_t, header: AXHeader?) async -> AXSnapshot? {
        guard AccessibilityPermission.isTrusted else { return nil }
        let limits = self.limits
        // Only this pid's elements are reusable — the frontmost app may have changed since.
        let reusable = header?.pid == pid ? header : nil
        // Off the main actor: one hung app must never stall a capture tick, and AX calls block.
        return await Task.detached(priority: .utility) {
            AccessibilitySnapshotter.take(pid: pid, limits: limits, header: reusable)
        }.value
    }

    /// The cheap read, on the caller's thread. Two round-trips — one
    /// `AXUIElementCopyMultipleAttributeValues` on the window plus `AXDocument` — under the same
    /// messaging timeout the walk uses, so a hung app costs at most half the walk budget.
    public func header(pid: pid_t) -> AXHeader? {
        guard AccessibilityPermission.isTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(limits.timeoutMs) / 2_000)
        guard let window = AccessibilitySnapshotter.window(of: app) else {
            // Trusted, but nothing to read: a header with no title and no URL, which the
            // collector treats exactly like a missing attribute.
            return AXHeader(pid: pid)
        }
        let focused = AccessibilitySnapshotter.copyElement(app, kAXFocusedUIElementAttribute as String)
        return AXHeader.make(
            pid: pid,
            window: AXLiveElement(window),
            focused: focused.map(AXLiveElement.init),
            documentURL: AccessibilitySnapshotter.copyString(window, kAXDocumentAttribute as String)
        )
    }

    public func resetEnhancedUserInterface(pid: pid_t) async {
        guard AccessibilityPermission.isTrusted else { return }
        _ = await Task.detached(priority: .utility) {
            AccessibilitySnapshotter.set(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface", false)
        }.value
    }

    /// Everything below runs on one detached task. No `AXUIElement` ever crosses a boundary:
    /// they are created here from the pid and dropped here.
    private static func take(pid: pid_t, limits: AXWalkLimits, header: AXHeader? = nil) -> AXSnapshot {
        let started = DispatchTime.now()
        let app = AXUIElementCreateApplication(pid)

        // The messaging timeout is the second half of the deadline: the walk checks the clock
        // between nodes, but a single hung `AXUIElementCopyMultipleAttributeValues` would block
        // past it without this. Half the walk budget, so one slow node cannot eat all of it.
        AXUIElementSetMessagingTimeout(app, Float(limits.timeoutMs) / 2_000)

        // Electron builds its tree only on request. Documented as side-effect-free, so it is set
        // unconditionally and never reset.
        let didSetManual = set(app, "AXManualAccessibility", true)

        var (snapshot, unbuiltWebTree) = walkOnce(
            app: app, limits: limits, startedAt: started, reusing: header
        )
        snapshot.didSetManualAccessibility = didSetManual

        // Chromium proper (Chrome, Edge, Brave, Arc) needs the older switch, which *does* have
        // side effects in some builds — so it is a second resort, and the snapshot says it
        // happened so #53 can turn it back off.
        //
        // "Still empty" is two cases, not one. A tree with nothing in it is the obvious one. The
        // other is a window whose own `AXDocument` says it is showing a web page while the tree
        // exposes no `AXWebArea` at all: that is a Chromium window that has not built its tree,
        // and it grades `.full` off the tab strip alone if left there. Neither test names an app.
        if snapshot.coverage == .none || unbuiltWebTree {
            if set(app, "AXEnhancedUserInterface", true) {
                // No `reusing:` on the second pass: element reads are memoised, and the point of
                // the switch is that the tree behind them is now a different tree.
                var second = walkOnce(app: app, limits: limits, startedAt: started).snapshot
                second.didSetManualAccessibility = didSetManual
                second.didSetEnhancedUserInterface = true
                if second.nodeCount > snapshot.nodeCount { return second }
                snapshot.didSetEnhancedUserInterface = true
            }
        }
        return snapshot
    }

    /// One walk. The second return value is the "this window says it is a web page but exposed no
    /// web area" signal `take` uses to decide on `AXEnhancedUserInterface`; it is not part of the
    /// snapshot, because nothing downstream has any use for it.
    private static func walkOnce(
        app: AXUIElement, limits: AXWalkLimits, startedAt: DispatchTime, reusing header: AXHeader? = nil
    ) -> (snapshot: AXSnapshot, unbuiltWebTree: Bool) {
        let deadline = Date().addingTimeInterval(Double(limits.timeoutMs) / 1_000)

        let windowSource: any AXElementSource
        let focusedSource: (any AXElementSource)?
        let documentURL: String?
        if let header, let window = header.window {
            // #55: the collector already resolved these before the blocklist ran, and their
            // reads are memoised — so this walk starts with the window and the focused element
            // in hand and pays nothing for them.
            windowSource = window
            focusedSource = header.focused
            documentURL = header.documentURL
        } else {
            guard let window = AccessibilitySnapshotter.window(of: app) else {
                return (AXSnapshot(coverage: .none, elapsedMs: elapsed(since: startedAt)), false)
            }
            windowSource = AXLiveElement(window)
            focusedSource = copyElement(app, kAXFocusedUIElementAttribute as String)
                .map(AXLiveElement.init)
            documentURL = copyString(window, kAXDocumentAttribute as String)
        }

        let result = AXWalker(limits: limits, deadline: deadline).walk(
            window: windowSource,
            focused: focusedSource
        )

        let text = AXOutline.render(
            nodes: result.nodes, focused: result.focused, maxChars: limits.maxTextChars
        )
        let snapshot = AXSnapshot(
            // From the window's own memoised read rather than a second `AXTitle` round-trip, so
            // the snapshot and the header can never name the window differently.
            windowTitle: header?.windowTitle ?? windowSource.read().title?.nonEmpty,
            documentURL: documentURL,
            webURL: result.webURL,
            focused: result.focused,
            nodes: result.nodes,
            text: text,
            textHash: AXOutline.hash(text),
            coverage: AXSnapshot.Coverage.classify(
                nodes: result.nodes.count,
                textChars: text.count,
                finished: result.finished,
                minChars: limits.minTextChars
            ),
            elapsedMs: elapsed(since: startedAt)
        )
        let unbuilt = !result.foundWebArea && (documentURL?.hasPrefix("http") ?? false)
        return (snapshot, unbuilt)
    }

    private static func elapsed(since started: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
    }

    // MARK: Raw AX helpers

    /// The focused window, else the main one. The header and the walk agree on this by calling
    /// the same function — a header that named one window while the walk read another would put
    /// a title on a frame whose text came from somewhere else.
    private static func window(of app: AXUIElement) -> AXUIElement? {
        copyElement(app, kAXFocusedWindowAttribute as String)
            ?? copyElement(app, kAXMainWindowAttribute as String)
    }

    @discardableResult
    private static func set(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean) == .success
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return (raw as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success
        else { return nil }
        return AXLiveElement.stringify(raw)?.nonEmpty
    }
}

// MARK: - AXUIElement as an element source

/// One `AXUIElement` behind the walk's protocol. Every attribute the walk needs comes back in a
/// single `AXUIElementCopyMultipleAttributeValues` — one IPC round-trip per node instead of nine —
/// and the read is memoised, because a stage may reach the same element twice.
final class AXLiveElement: AXElementSource {
    private let element: AXUIElement
    private var cached: AXElementRead?

    init(_ element: AXUIElement) {
        self.element = element
    }

    /// `CFEqual`, not pointer identity: the same element fetched twice is two objects.
    var identity: AnyHashable { AnyHashable(Key(element)) }

    private struct Key: Hashable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
        static func == (lhs: Key, rhs: Key) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    /// The attribute order below is the index order used in `read()`; keep them together.
    private static let attributes: CFArray = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, "AXURL", "AXFrame", kAXChildrenAttribute, kAXParentAttribute,
    ] as CFArray

    func read() -> AXElementRead {
        if let cached { return cached }
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, AXLiveElement.attributes, [], &raw)
        guard status == .success, let values = raw as? [CFTypeRef], values.count == 9 else {
            let empty = AXElementRead()
            cached = empty
            return empty
        }

        // `values[4]` is `kAXValueAttribute`. It is deliberately *not* unwrapped here: the walk
        // asks for it through this closure, and for an `AXSecureTextField` it never asks. That is
        // the privacy invariant of #52, and it is the reason `value` is a call and not a field.
        let secureSlot = values[4]
        let read = AXElementRead(
            role: AXLiveElement.stringify(values[0]),
            subrole: AXLiveElement.stringify(values[1]),
            title: AXLiveElement.stringify(values[2]),
            description: AXLiveElement.stringify(values[3]),
            url: AXLiveElement.stringify(values[5]),
            frame: AXLiveElement.rect(values[6]),
            children: AXLiveElement.elements(values[7]),
            parent: AXLiveElement.elements(values[8]).first,
            value: { AXLiveElement.stringify(secureSlot) }
        )
        cached = read
        return read
    }

    // MARK: Decoding one slot

    /// A slot may hold a string, a number, a URL, an attributed string, or an `AXValue` carrying
    /// the error for that one attribute — the price of asking for nine things at once.
    static func stringify(_ raw: CFTypeRef?) -> String? {
        guard let raw else { return nil }
        if CFGetTypeID(raw) == AXValueGetTypeID() { return nil }
        if let string = raw as? String { return string }
        if let url = raw as? URL { return url.absoluteString }
        if let attributed = raw as? NSAttributedString { return attributed.string }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    static func rect(_ raw: CFTypeRef?) -> CGRect? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }

    static func elements(_ raw: CFTypeRef?) -> [AXLiveElement] {
        guard let raw else { return [] }
        if CFGetTypeID(raw) == AXUIElementGetTypeID() {
            // swiftlint:disable:next force_cast
            return [AXLiveElement(raw as! AXUIElement)]
        }
        guard CFGetTypeID(raw) == CFArrayGetTypeID(), let array = raw as? [CFTypeRef] else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            // swiftlint:disable:next force_cast
            return AXLiveElement(item as! AXUIElement)
        }
    }
}
