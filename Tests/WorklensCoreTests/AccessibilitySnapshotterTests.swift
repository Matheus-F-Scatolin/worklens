import CoreGraphics
import Foundation
import Testing
@testable import WorklensCore

// MARK: - A fixture tree

/// An `AXElementSource` made of plain values. Nothing here touches the accessibility API, so the
/// walk is tested with no windows on screen, no permission and no timing luck.
///
/// It also *records* every read of a node's value, which is how the secure-field invariant is
/// asserted rather than assumed.
final class FakeElement: AXElementSource, @unchecked Sendable {
    let role: String
    let subrole: String?
    let title: String?
    let label: String?
    let url: String?
    let frame: CGRect?
    private(set) var children: [FakeElement]
    weak var parentElement: FakeElement?

    /// What `AXValue` would return. Reading it is recorded in `valueReads`.
    private let rawValue: String?
    private(set) var valueReads = 0
    /// Cache misses — the IPC round-trip count. The live `AXLiveElement` memoises the same way,
    /// so a stage reaching an element a second time costs nothing.
    private(set) var reads = 0
    private var cached: AXElementRead?
    /// Set on a node whose read should hang past the deadline.
    var readDelay: TimeInterval = 0
    private let clock: Clock?

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 0)
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    init(
        _ role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        label: String? = nil,
        url: String? = nil,
        frame: CGRect? = nil,
        clock: Clock? = nil,
        children: [FakeElement] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.rawValue = value
        self.label = label
        self.url = url
        self.frame = frame
        self.clock = clock
        self.children = children
        for child in children { child.parentElement = self }
    }

    var identity: AnyHashable { ObjectIdentifier(self) }

    func read() -> AXElementRead {
        if let cached { return cached }
        reads += 1
        if readDelay > 0 { clock?.advance(readDelay) }
        let read = AXElementRead(
            role: role,
            subrole: subrole,
            title: title,
            description: label,
            url: url,
            frame: frame,
            children: children,
            parent: parentElement,
            value: { [self] in
                valueReads += 1
                return rawValue
            }
        )
        cached = read
        return read
    }

    /// Depth-first, for assertions about the whole fixture.
    func descendants() -> [FakeElement] {
        children.flatMap { [$0] + $0.descendants() }
    }

    func find(title: String) -> FakeElement? {
        ([self] + descendants()).first { $0.title == title }
    }
}

// MARK: - Fixtures

/// Shaped like a browser on Gmail: the message body the user is typing in sits eleven levels
/// down, behind the tab strip and the toolbar. This is the tree a breadth-first walk from the
/// root never reaches within a node budget, which is the whole reason for the focused-first order.
private func gmailWindow(clock: FakeElement.Clock? = nil) -> (window: FakeElement, focused: FakeElement) {
    let body = FakeElement(
        "AXTextArea", title: "Message body",
        value: "Thanks for the update — I will send the revised deck tomorrow morning.",
        clock: clock
    )
    var node = FakeElement(
        "AXGroup", clock: clock,
        children: [
            FakeElement("AXHeading", title: "Revised deck for Thursday", clock: clock),
            FakeElement("AXStaticText", value: "ana.ribeiro@exemplo.com.br", clock: clock),
            body,
        ]
    )
    // Bury it under nine more anonymous groups: real web trees are like this.
    for _ in 0..<9 {
        node = FakeElement("AXGroup", clock: clock, children: [node])
    }
    let webArea = FakeElement(
        "AXWebArea", title: "Inbox (12)", url: "https://mail.google.com/mail/u/0/#inbox",
        frame: CGRect(x: 0, y: 0, width: 1_400, height: 900), clock: clock, children: [node]
    )
    let toolbar = FakeElement(
        "AXToolbar", clock: clock,
        children: (0..<40).map { FakeElement("AXButton", title: "Toolbar \($0)", clock: clock) }
    )
    let tabs = FakeElement(
        "AXTabGroup", clock: clock,
        children: (0..<20).map { FakeElement("AXTab", title: "Tab \($0)", clock: clock) }
    )
    let window = FakeElement(
        "AXWindow", title: "Inbox (12) — ana@exemplo.com.br", clock: clock,
        children: [tabs, toolbar, webArea]
    )
    return (window, body)
}

// MARK: - Walk order

@Suite("AX walk order")
struct AXWalkOrderTests {
    private func walk(
        _ window: FakeElement, focused: FakeElement?, limits: AXWalkLimits = AXWalkLimits()
    ) -> AXWalkResult {
        AXWalker(limits: limits, deadline: .distantFuture).walk(window: window, focused: focused)
    }

    @Test("the focused element's subtree comes before the tab strip, however deep it is")
    func focusedFirst() {
        let (window, body) = gmailWindow()
        let result = walk(window, focused: body, limits: AXWalkLimits(maxNodes: 30))

        let text = AXOutline.render(nodes: result.nodes, focused: result.focused, maxChars: 3_000)
        // What the acceptance criterion asks for: the message, not just the chrome.
        #expect(text.contains("Message body"))
        #expect(text.contains("revised deck tomorrow morning"))

        let bodyIndex = try! #require(result.nodes.firstIndex { $0.title == "Message body" })
        let tabIndex = result.nodes.firstIndex { $0.title == "Tab 0" }
        #expect(tabIndex == nil || bodyIndex < tabIndex!)
    }

    @Test("a breadth-first walk from the root under the same budget would not have reached it")
    func breadthFirstWouldMissIt() {
        let (window, _) = gmailWindow()
        // No focused element: stage 1 and 2 do nothing, so this is the plain walk the issue
        // rejects — except stage 3 still jumps to the web area, which is the second half of the
        // fix. Take the web area out and the message is unreachable inside the budget.
        let flat = FakeElement(
            "AXWindow", title: window.title,
            children: window.descendants().filter { $0.role == "AXTabGroup" || $0.role == "AXToolbar" }
        )
        let result = walk(flat, focused: nil, limits: AXWalkLimits(maxNodes: 30))
        #expect(!result.nodes.contains { $0.title == "Message body" })
    }

    @Test("titled ancestors come out first, as breadcrumbs, and untitled groups do not")
    func ancestryIsBreadcrumbs() {
        let (window, body) = gmailWindow()
        let result = walk(window, focused: body, limits: AXWalkLimits(maxNodes: 60))
        let titles = result.nodes.compactMap(\.title)
        let webAreaIndex = try! #require(titles.firstIndex(of: "Inbox (12)"))
        let bodyIndex = try! #require(titles.firstIndex(of: "Message body"))
        #expect(webAreaIndex < bodyIndex)
        // The nine anonymous groups between them are scaffolding, not breadcrumbs.
        #expect(result.nodes.filter { $0.role == "AXGroup" }.isEmpty)
    }

    @Test("no node is emitted twice, however many stages reach it")
    func noDuplicates() {
        let (window, body) = gmailWindow()
        let result = walk(window, focused: body, limits: AXWalkLimits(maxNodes: 400))
        let keys = result.nodes.map { "\($0.role)|\($0.title ?? "")|\($0.value ?? "")|\($0.depth)" }
        #expect(Set(keys).count == keys.count)
        // One IPC round-trip per element, however many stages reach it.
        #expect(([window] + window.descendants()).allSatisfy { $0.reads <= 1 })
    }

    @Test("stage 3 finds the web area even with nothing focused")
    func mainContentWithoutFocus() {
        let (window, _) = gmailWindow()
        let result = walk(window, focused: nil, limits: AXWalkLimits(maxNodes: 40))
        #expect(result.nodes.contains { $0.title == "Message body" })
    }

    @Test("the page address comes off the web area the content search already read")
    func webURLFromContent() {
        let (window, body) = gmailWindow()
        let result = walk(window, focused: body)
        #expect(result.foundWebArea)
        #expect(result.webURL == "https://mail.google.com/mail/u/0/#inbox")
    }

    @Test("a window with no web area reports none, which is what asks for AXEnhancedUserInterface")
    func noWebArea() {
        let window = FakeElement("AXWindow", title: "Finder", children: [
            FakeElement("AXStaticText", value: "Documents"),
        ])
        let result = walk(window, focused: nil)
        #expect(result.foundWebArea == false)
        #expect(result.webURL == nil)
    }

    @Test("with no web area, the largest scroll area is the content")
    func largestScrollArea() {
        let small = FakeElement(
            "AXScrollArea", frame: CGRect(x: 0, y: 0, width: 200, height: 400),
            children: [FakeElement("AXStaticText", value: "sidebar item")]
        )
        let big = FakeElement(
            "AXScrollArea", frame: CGRect(x: 200, y: 0, width: 1_200, height: 800),
            children: [FakeElement("AXStaticText", value: "the actual document")]
        )
        let window = FakeElement("AXWindow", title: "Notes", children: [small, big])
        let result = walk(window, focused: nil, limits: AXWalkLimits(maxNodes: 3))
        let text = AXOutline.render(nodes: result.nodes, focused: nil, maxChars: 3_000)
        #expect(text.contains("the actual document"))
    }
}

// MARK: - Budget, depth, deadline

@Suite("AX walk limits")
struct AXWalkLimitTests {
    @Test("the node budget is shared by every stage and stops the walk unfinished")
    func nodeBudget() {
        let (window, body) = gmailWindow()
        let result = AXWalker(limits: AXWalkLimits(maxNodes: 12), deadline: .distantFuture)
            .walk(window: window, focused: body)
        #expect(result.nodes.count <= 12)
        #expect(result.finished == false)
    }

    @Test("the deadline stops the walk and what was collected is kept")
    func deadline() {
        let clock = FakeElement.Clock()
        let (window, body) = gmailWindow(clock: clock)
        // Every node costs 20 ms of the fixture's clock; the deadline is 100 ms out.
        for element in [window] + window.descendants() { element.readDelay = 0.02 }
        let deadline = clock.now.addingTimeInterval(0.1)
        let result = AXWalker(limits: AXWalkLimits(), deadline: deadline, now: { clock.now })
            .walk(window: window, focused: body)

        #expect(result.finished == false)
        #expect(result.nodes.isEmpty == false)
        #expect(result.nodes.count < 400)
    }

    @Test("a stage does not descend past AX_MAX_DEPTH")
    func depthLimit() {
        var leaf = FakeElement("AXStaticText", value: "bottom of the world")
        for index in 0..<20 { leaf = FakeElement("AXGroup", title: "level \(index)", children: [leaf]) }
        let window = FakeElement("AXWindow", title: "deep", children: [leaf])

        let shallow = AXWalker(limits: AXWalkLimits(maxDepth: 4), deadline: .distantFuture)
            .walk(window: window, focused: nil)
        #expect(!shallow.nodes.contains { $0.value == "bottom of the world" })

        let deep = AXWalker(limits: AXWalkLimits(maxDepth: 24), deadline: .distantFuture)
            .walk(window: window, focused: nil)
        #expect(deep.nodes.contains { $0.value == "bottom of the world" })
    }
}

// MARK: - The privacy invariant

@Suite("AX secure fields")
struct AXSecureFieldTests {
    @Test("a secure text field's value is never even asked for")
    func secureRole() {
        let secure = FakeElement("AXSecureTextField", title: "Password", value: "hunter2")
        let ordinary = FakeElement("AXTextField", title: "Email", value: "ana@exemplo.com.br")
        let window = FakeElement("AXWindow", title: "Sign in", children: [ordinary, secure])

        let result = AXWalker(limits: AXWalkLimits(), deadline: .distantFuture)
            .walk(window: window, focused: secure)

        #expect(secure.valueReads == 0)
        #expect(ordinary.valueReads >= 1)

        let text = AXOutline.render(nodes: result.nodes, focused: result.focused, maxChars: 3_000)
        #expect(text.contains("AXSecureTextField"))
        #expect(!text.contains("hunter2"))
        // The role is still worth printing: that a password field has focus is the useful fact.
        #expect(text.contains("Password"))
    }

    @Test("a web password input carries the subrole instead, and is treated the same")
    func secureSubrole() {
        let secure = FakeElement(
            "AXTextField", subrole: "AXSecureTextField", title: "Senha", value: "hunter2"
        )
        let window = FakeElement("AXWindow", title: "Entrar", children: [secure])
        let result = AXWalker(limits: AXWalkLimits(), deadline: .distantFuture)
            .walk(window: window, focused: secure)
        #expect(secure.valueReads == 0)
        #expect(!AXOutline.render(nodes: result.nodes, focused: nil, maxChars: 3_000).contains("hunter2"))
    }

    @Test("a long value is cut to 200 characters")
    func valueTruncation() {
        let long = String(repeating: "x", count: 900)
        let field = FakeElement("AXTextArea", title: "Notes", value: long)
        let window = FakeElement("AXWindow", title: "Notes", children: [field])
        let result = AXWalker(limits: AXWalkLimits(), deadline: .distantFuture)
            .walk(window: window, focused: nil)
        let node = try! #require(result.nodes.first { $0.title == "Notes" && $0.value != nil })
        #expect(node.value?.count == 200)
    }
}

// MARK: - Outline, coverage, hash

@Suite("AX outline")
struct AXOutlineTests {
    private let nodes = [
        AXNode(role: "AXWebArea", title: "Inbox (12)", depth: 0),
        AXNode(role: "AXHeading", title: "Revised deck", depth: 1),
        AXNode(role: "AXStaticText", value: "Thanks for the update", depth: 2),
    ]

    @Test("the format is [role] title — value, indented by depth")
    func format() {
        let text = AXOutline.render(nodes: nodes, focused: nil, maxChars: 3_000)
        #expect(text == """
            [AXWebArea] Inbox (12)
              [AXHeading] Revised deck
                [AXStaticText] Thanks for the update
            """)
    }

    @Test("the focused node is named on the first line")
    func focusedHeader() {
        let focused = AXNode(role: "AXTextArea", title: "Message body")
        let text = AXOutline.render(nodes: nodes, focused: focused, maxChars: 3_000)
        #expect(text.hasPrefix("focused: [AXTextArea] Message body\n"))
    }

    @Test("rendering is deterministic and duplicate lines are dropped")
    func determinismAndDedup() {
        let doubled = nodes + nodes
        let once = AXOutline.render(nodes: nodes, focused: nil, maxChars: 3_000)
        let twice = AXOutline.render(nodes: doubled, focused: nil, maxChars: 3_000)
        #expect(once == twice)
        #expect(AXOutline.render(nodes: nodes, focused: nil, maxChars: 3_000) == once)
    }

    @Test("too long keeps the head and the tail, on line boundaries")
    func truncation() {
        let many = (0..<400).map { AXNode(role: "AXStaticText", value: "line \($0)") }
        let text = AXOutline.render(nodes: many, focused: nil, maxChars: 500)
        #expect(text.count <= 500)
        #expect(text.contains("line 0"))
        #expect(text.contains("line 399"))
        #expect(text.contains("\n…\n"))
        // Whole lines only: no half-printed node.
        #expect(text.split(separator: "\n").allSatisfy { $0 == "…" || $0.hasPrefix("[AXStaticText]") })
    }

    @Test("the hash is stable for the same outline and moves for a different one")
    func hashing() {
        let text = AXOutline.render(nodes: nodes, focused: nil, maxChars: 3_000)
        #expect(AXOutline.hash(text) == AXOutline.hash(text))
        #expect(AXOutline.hash(text).count == 64)
        #expect(AXOutline.hash(text) != AXOutline.hash(text + "!"))
        #expect(AXOutline.hash("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}

@Suite("AX coverage")
struct AXCoverageTests {
    private func classify(nodes: Int, chars: Int, finished: Bool) -> AXSnapshot.Coverage {
        AXSnapshot.Coverage.classify(nodes: nodes, textChars: chars, finished: finished, minChars: 80)
    }

    @Test("full needs a finished walk and the minimum text")
    func full() {
        #expect(classify(nodes: 40, chars: 900, finished: true) == .full)
        #expect(classify(nodes: 40, chars: 80, finished: true) == .full)
    }

    @Test("partial is a walk that was cut short, or one that came in under the minimum")
    func partial() {
        #expect(classify(nodes: 400, chars: 2_900, finished: false) == .partial)
        #expect(classify(nodes: 40, chars: 79, finished: true) == .partial)
    }

    @Test("none is one node, or no text at all")
    func none() {
        #expect(classify(nodes: 1, chars: 400, finished: true) == .none)
        #expect(classify(nodes: 0, chars: 0, finished: true) == .none)
        #expect(classify(nodes: 40, chars: 0, finished: false) == .none)
    }

    @Test("a canvas-like window with nothing to say grades none")
    func canvas() {
        let window = FakeElement("AXWindow", title: "Untitled — Figma", children: [
            FakeElement("AXGroup", children: [FakeElement("AXImage")]),
        ])
        let result = AXWalker(limits: AXWalkLimits(), deadline: .distantFuture)
            .walk(window: window, focused: nil)
        let text = AXOutline.render(nodes: result.nodes, focused: nil, maxChars: 3_000)
        #expect(classify(nodes: result.nodes.count, chars: text.count, finished: result.finished) == .none)
    }
}

// MARK: - Limits

@Suite("AX limits")
struct AXLimitsTests {
    @Test("the five limits ship with their documented values")
    func defaults() {
        let limits = AXWalkLimits()
        #expect(limits.maxNodes == 400)
        #expect(limits.maxDepth == 24)
        #expect(limits.timeoutMs == 250)
        #expect(limits.maxTextChars == 3_000)
        #expect(limits.minTextChars == 80)
    }
}

// MARK: - The header (#55)

@Suite("AX header")
struct AXHeaderTests {
    /// Every cache miss in the fixture — the IPC round-trip count for a whole tree.
    private func reads(_ window: FakeElement) -> Int {
        ([window] + window.descendants()).reduce(0) { $0 + $1.reads }
    }

    @Test("The header reads the window and the focused element, and walks nothing")
    func readsTwoElementsAndNoMore() {
        let (window, body) = gmailWindow()
        let header = AXHeader.make(pid: 42, window: window, focused: body, documentURL: nil)

        #expect(header.pid == 42)
        #expect(header.windowTitle == "Inbox (12) — ana@exemplo.com.br")
        #expect(window.reads == 1)
        #expect(body.reads == 1)
        // The web area is one level down with the URL on it; finding it is the walk's job, and a
        // header that went looking would be a walk with a smaller budget.
        #expect(window.descendants().filter { $0 !== body }.allSatisfy { $0.reads == 0 })
        #expect(reads(window) == 2)
        #expect(header.webURL == nil)
    }

    @Test("The window's own AXURL is the page, when it has one — this is Firefox's answer")
    func urlFromTheWindow() {
        let window = FakeElement(
            "AXWindow", title: "Swift Testing — Mozilla Firefox",
            url: "https://swift.org/documentation/testing/"
        )
        let header = AXHeader.make(pid: 1, window: window, focused: nil, documentURL: nil)
        #expect(header.webURL == "https://swift.org/documentation/testing/")
        #expect(header.windowTitle == "Swift Testing — Mozilla Firefox")
    }

    @Test("A focused element that *is* the web area answers, and one inside it does not")
    func urlFromTheFocusedWebArea() {
        let webArea = FakeElement("AXWebArea", title: "Inbox", url: "https://mail.google.com/mail/u/0")
        let link = FakeElement("AXLink", title: "Unsubscribe", url: "https://ads.example.com/out")
        let window = FakeElement("AXWindow", title: "Inbox", children: [webArea, link])

        #expect(AXHeader.make(pid: 1, window: window, focused: webArea, documentURL: nil).webURL
            == "https://mail.google.com/mail/u/0")
        // A link's `AXURL` is a page the user is not on — the one wrong answer available here.
        #expect(AXHeader.make(pid: 1, window: window, focused: link, documentURL: nil).webURL == nil)
    }

    @Test("An http AXDocument is the page — how a Chromium window names its tab")
    func urlFromTheDocument() {
        let window = FakeElement("AXWindow", title: "Inbox (12) - Google Chrome")
        let header = AXHeader.make(
            pid: 1, window: window, focused: nil, documentURL: "https://mail.google.com/mail/u/0"
        )
        #expect(header.documentURL == "https://mail.google.com/mail/u/0")
        #expect(header.webURL == "https://mail.google.com/mail/u/0")
    }

    @Test("A file AXDocument is a document, not a page")
    func fileDocumentIsNotAPage() {
        let window = FakeElement("AXWindow", title: "plan.md — Zed")
        let header = AXHeader.make(
            pid: 1, window: window, focused: nil, documentURL: "file:///Users/someone/plan.md"
        )
        #expect(header.documentURL == "file:///Users/someone/plan.md")
        #expect(header.webURL == nil)
    }

    @Test("A window with nothing to say yields a header with nothing in it, not a nil header")
    func emptyWindow() {
        let window = FakeElement("AXWindow")
        let header = AXHeader.make(pid: 1, window: window, focused: nil, documentURL: nil)
        #expect(header.windowTitle == nil)
        #expect(header.webURL == nil)
        #expect(header.documentURL == nil)
    }

    @Test("A focused secure field's value is never read — the header asks the same as the walk")
    func secureFieldValueIsNeverRead() {
        let secure = FakeElement("AXSecureTextField", title: "Password", value: "hunter2")
        let window = FakeElement("AXWindow", title: "Sign in — Bank", children: [secure])
        let header = AXHeader.make(pid: 1, window: window, focused: secure, documentURL: nil)
        #expect(header.windowTitle == "Sign in — Bank")
        #expect(header.webURL == nil)
        #expect(secure.valueReads == 0)
    }

    @Test("The walk that follows a header costs exactly what the walk alone would have")
    func headerCostsTheWalkNothing() {
        // Baseline: #53's walk, over its own freshly resolved window and focused element.
        let plain = gmailWindow()
        _ = AXWalker(limits: AXWalkLimits(), deadline: .distantFuture)
            .walk(window: plain.window, focused: plain.focused)
        let baseline = reads(plain.window)

        // #55: the header first, then the walk over the *same* elements — which is what
        // `snapshot(pid:header:)` hands it. Reads are memoised per element, so the header's two
        // are the walk's two and the tick pays for neither twice.
        let shared = gmailWindow()
        let header = AXHeader.make(
            pid: 42, window: shared.window, focused: shared.focused, documentURL: nil
        )
        let window = try! #require(header.window)
        _ = AXWalker(limits: AXWalkLimits(), deadline: .distantFuture)
            .walk(window: window, focused: header.focused)

        #expect(reads(shared.window) == baseline)
        #expect(shared.window.reads == 1)
        #expect(shared.focused.reads == 1)
    }
}
