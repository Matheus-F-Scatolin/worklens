import CoreGraphics
import CryptoKit
import Foundation

// MARK: - The tree, as much of it as the walk needs

/// One node of an accessibility tree, flattened.
public struct AXNode: Sendable, Equatable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var value: String?
    /// `AXDescription` — the label a screen reader would read for an unlabelled control.
    public var description: String?
    public var frame: CGRect?
    /// Indentation in the outline: depth below the root of the stage that emitted this node.
    public var depth: Int

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        frame: CGRect? = nil,
        depth: Int = 0
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.frame = frame
        self.depth = depth
    }

    /// Everything the outline prints for this node, in order.
    var texts: [String] { [title, description, value].compactMap { $0?.nonEmpty } }
    var hasText: Bool { !texts.isEmpty }
}

/// What one IPC round-trip returns about one element.
///
/// `value` is a *call*, not a stored property, and that is the whole point: the walk decides not
/// to read the value of a secure text field, rather than reading it and throwing it away. The
/// fixture source in the tests records every call, so the invariant is testable.
public struct AXElementRead {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var description: String?
    /// `AXURL`, which only an `AXWebArea` (and a Finder window) carries.
    public var url: String?
    public var frame: CGRect?
    public var children: [any AXElementSource]
    public var parent: (any AXElementSource)?
    public var value: () -> String?

    public init(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        url: String? = nil,
        frame: CGRect? = nil,
        children: [any AXElementSource] = [],
        parent: (any AXElementSource)? = nil,
        value: @escaping () -> String? = { nil }
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.url = url
        self.frame = frame
        self.children = children
        self.parent = parent
        self.value = value
    }
}

/// The seam that keeps the walk testable: the real `AXUIElement` and a fixture tree both
/// implement it, and no test ever touches the live accessibility API.
public protocol AXElementSource: AnyObject {
    /// Identity for the visited sets. Two `AXUIElement`s can be different objects and the same
    /// element, so the live implementation compares with `CFEqual`, not by pointer.
    var identity: AnyHashable { get }
    /// One round-trip. Called at most once per element per walk.
    func read() -> AXElementRead
}

// MARK: - Roles

/// Which roles carry text, which are scaffolding, and which container is "the content".
public enum AXRoles {
    /// Emitted when they carry a title, a description or a value.
    public static let textBearing: Set<String> = [
        "AXStaticText", "AXTextField", "AXTextArea", "AXHeading", "AXLink", "AXButton",
        "AXMenuItem", "AXMenuBarItem", "AXCell", "AXTab", "AXRadioButton", "AXRow",
        "AXCheckBox", "AXPopUpButton", "AXComboBox", "AXImage", "AXDisclosureTriangle",
    ]
    /// Descended into, but only emitted when they have a title of their own.
    public static let containers: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXWebArea", "AXList", "AXTable",
        "AXOutline", "AXTabGroup", "AXToolbar", "AXSplitter", "AXLayoutArea", "AXUnknown",
        "AXScrollBar", "AXWindow", "AXApplication", "AXSheet", "AXDrawer",
    ]
    /// A password field, whose value is never read. Web password inputs carry it as a *subrole*
    /// on an `AXTextField`, so both are checked.
    public static let secureTextField = "AXSecureTextField"
    /// The main content container, in preference order.
    public static let webArea = "AXWebArea"
    public static let contentCandidates: Set<String> = ["AXScrollArea", "AXGroup"]

    public static func isSecure(role: String?, subrole: String?) -> Bool {
        role == secureTextField || subrole == secureTextField
    }
}

// MARK: - Limits

/// What one walk may spend, in one value so the walk takes one argument.
///
/// These were the five `AX_*` `.env` keys until #87; nobody tuned them, so the shipped values
/// are the defaults below and only tests pass anything else.
public struct AXWalkLimits: Sendable, Equatable {
    /// The node budget one walk may spend, across all four stages.
    public var maxNodes: Int
    /// A safety net per stage — the focused-first order is what makes depth mostly irrelevant.
    public var maxDepth: Int
    /// The wall-clock deadline for one walk; it returns whatever it has and grades `.partial`.
    public var timeoutMs: Int
    /// The outline is cut to this many characters, head and tail.
    public var maxTextChars: Int
    /// Below this, a window with a tree is still graded `.partial`.
    public var minTextChars: Int
    /// `kAXValueAttribute` never contributes more than this to one line.
    public static let maxValueChars = 200

    public init(
        maxNodes: Int = 400,
        maxDepth: Int = 24,
        timeoutMs: Int = 250,
        maxTextChars: Int = 3_000,
        minTextChars: Int = 80
    ) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.timeoutMs = timeoutMs
        self.maxTextChars = maxTextChars
        self.minTextChars = minTextChars
    }
}

// MARK: - The walk

public struct AXWalkResult: Sendable {
    public var nodes: [AXNode]
    public var focused: AXNode?
    /// The `AXURL` of the `AXWebArea` stage 3 found, when it found one. Free: that element was
    /// read anyway, so the page address costs no extra round-trip and no extra deadline (#55).
    public var webURL: String?
    /// Whether stage 3 found an `AXWebArea` at all. A window that the OS says is showing a web
    /// document but that exposes no web area is a Chromium tree that has not been built yet.
    public var foundWebArea: Bool = false
    /// `false` when the node budget or the deadline stopped it — which is what turns a snapshot
    /// with plenty of text into `.partial`.
    public var finished: Bool
}

/// Focused-first, because a breadth-first walk from the window root spends its whole budget on
/// tab strips and toolbars and never reaches a Gmail message body (#50).
///
/// Four stages, one shared node budget, one depth limit per stage and one deadline:
///
/// 1. the focused element's **ancestry**, titled nodes only — the breadcrumbs (tab, section);
/// 2. the focused element's **subtree** — what the user is actually looking at;
/// 3. the **main content container**: the `AXWebArea`, else the largest `AXScrollArea`/`AXGroup`;
/// 4. **the rest of the window**.
///
/// Emission and expansion are tracked separately: an ancestor emitted in stage 1 is *not* marked
/// expanded, so stage 4 can still descend through it, and nothing is emitted twice.
public struct AXWalker {
    let limits: AXWalkLimits
    let deadline: Date
    let now: () -> Date

    public init(limits: AXWalkLimits, deadline: Date, now: @escaping () -> Date = { Date() }) {
        self.limits = limits
        self.deadline = deadline
        self.now = now
    }

    public func walk(window: any AXElementSource, focused: (any AXElementSource)?) -> AXWalkResult {
        var state = State()

        var focusedNode: AXNode?
        if let focused {
            // Stage 1: ancestry, root-first, so the outline reads as breadcrumbs.
            var chain: [any AXElementSource] = []
            var cursor: (any AXElementSource)? = focused.read().parent
            var guardrail = 0
            while let element = cursor, guardrail < limits.maxDepth {
                guardrail += 1
                if element.identity == window.identity { chain.append(element); break }
                chain.append(element)
                cursor = element.read().parent
            }
            for (offset, element) in chain.reversed().enumerated() {
                let read = element.read()
                // Titled only: an untitled group is not a breadcrumb, it is scaffolding.
                guard read.title?.nonEmpty != nil else { continue }
                emit(element, read: read, depth: offset, into: &state)
            }

            // Stage 2: the focused element and everything under it.
            let read = focused.read()
            focusedNode = node(for: read, depth: chain.count)
            bfs(from: focused, depth: chain.count, into: &state)
        }

        // Stage 3: the main content container.
        var webURL: String?
        var foundWebArea = false
        if let content = mainContent(of: window, state: &state) {
            let read = content.read()
            if read.role == AXRoles.webArea {
                foundWebArea = true
                webURL = read.url?.nonEmpty
            }
            bfs(from: content, depth: 1, into: &state)
        }

        // Stage 4: whatever is left of the window.
        bfs(from: window, depth: 0, into: &state)

        return AXWalkResult(
            nodes: state.nodes, focused: focusedNode, webURL: webURL,
            foundWebArea: foundWebArea, finished: !state.stopped
        )
    }

    // MARK: Stages

    private struct State {
        var nodes: [AXNode] = []
        var emitted: Set<AnyHashable> = []
        var expanded: Set<AnyHashable> = []
        var stopped = false
    }

    private func exhausted(_ state: State) -> Bool {
        state.nodes.count >= limits.maxNodes || now() >= deadline
    }

    /// Breadth-first from one root, bounded by the shared budget and this stage's own depth limit.
    private func bfs(from root: any AXElementSource, depth rootDepth: Int, into state: inout State) {
        var queue: [(element: any AXElementSource, depth: Int)] = [(root, rootDepth)]
        var index = 0
        while index < queue.count {
            if exhausted(state) { state.stopped = true; return }
            let (element, depth) = queue[index]
            index += 1
            guard !state.expanded.contains(element.identity) else { continue }
            state.expanded.insert(element.identity)

            let read = element.read()
            emit(element, read: read, depth: depth, into: &state)
            guard depth - rootDepth < limits.maxDepth else { continue }
            for child in read.children {
                queue.append((child, depth + 1))
            }
        }
    }

    /// The `AXWebArea` if there is one, else the largest `AXScrollArea`/`AXGroup` by area. Found
    /// breadth-first with its own small budget: this is a lookup, not a walk, and it must not eat
    /// the node budget the content itself needs.
    private func mainContent(of window: any AXElementSource, state: inout State) -> (any AXElementSource)? {
        var queue: [(element: any AXElementSource, depth: Int)] = [(window, 0)]
        var index = 0
        var best: (element: any AXElementSource, area: CGFloat)?
        var seen = 0
        while index < queue.count, seen < AXWalker.contentSearchBudget {
            if now() >= deadline { state.stopped = true; break }
            let (element, depth) = queue[index]
            index += 1
            seen += 1
            let read = element.read()
            if read.role == AXRoles.webArea { return element }
            if let role = read.role, AXRoles.contentCandidates.contains(role) {
                let area = (read.frame?.width ?? 0) * (read.frame?.height ?? 0)
                if area > (best?.area ?? 0) { best = (element, area) }
            }
            guard depth < AXWalker.contentSearchDepth else { continue }
            for child in read.children { queue.append((child, depth + 1)) }
        }
        return best?.element
    }

    /// A web area sits a few levels under the window in every browser; a scroll area is shallower
    /// still. Twelve levels and 120 elements find both without paying for the whole tree.
    static let contentSearchDepth = 12
    static let contentSearchBudget = 120

    // MARK: Emitting

    private func emit(
        _ element: any AXElementSource, read: AXElementRead, depth: Int, into state: inout State
    ) {
        guard !state.emitted.contains(element.identity) else { return }
        guard let candidate = node(for: read, depth: depth) else { return }
        state.emitted.insert(element.identity)
        state.nodes.append(candidate)
    }

    /// `nil` for a node with nothing to say: an untitled container is scaffolding, not content.
    private func node(for read: AXElementRead, depth: Int) -> AXNode? {
        let role = read.role ?? "AXUnknown"
        let isSecure = AXRoles.isSecure(role: role, subrole: read.subrole)
        // The one privacy invariant of the walk: `read.value` is a call, and for a secure field
        // it is never made. The role and the label still go in, so the outline can say a password
        // field is focused without saying what is in it.
        let value = isSecure ? nil : read.value()?.nonEmpty?.truncated(to: AXWalkLimits.maxValueChars)

        var node = AXNode(
            role: role,
            subrole: read.subrole?.nonEmpty,
            title: read.title?.nonEmpty,
            value: value,
            description: read.description?.nonEmpty,
            frame: read.frame,
            depth: depth
        )
        // A container earns a line only when it is titled; a text-bearing role earns one whenever
        // it carries anything at all. A secure field is always worth a line, value or not.
        if isSecure { node.value = nil; return node }
        if AXRoles.textBearing.contains(role) { return node.hasText ? node : nil }
        if AXRoles.containers.contains(role) { return node.title != nil ? node : nil }
        return node.hasText ? node : nil
    }
}

// MARK: - Outline

/// The deterministic text form of a walk: what gets hashed, stored and (from #54) sent.
public enum AXOutline {
    /// `[role] title — value`, indented by depth, focused subtree first (the walk already emits
    /// in that order), duplicate lines dropped, head and tail kept when it is too long.
    public static func render(nodes: [AXNode], focused: AXNode?, maxChars: Int) -> String {
        var lines: [String] = []
        var seen: Set<String> = []
        if let focused, let line = self.line(for: focused, indent: 0) {
            lines.append("focused: " + line)
            seen.insert(lines[0])
        }
        for node in nodes {
            guard let line = self.line(for: node, indent: min(node.depth, AXOutline.maxIndent)) else { continue }
            guard seen.insert(line).inserted else { continue }
            lines.append(line)
        }
        return truncate(lines.joined(separator: "\n"), to: maxChars)
    }

    static let maxIndent = 8
    /// How much of the budget the head keeps when the outline has to be cut. The tail is worth
    /// keeping too: the newest message in a thread is at the bottom.
    static let headShare = 0.6

    private static func line(for node: AXNode, indent: Int) -> String? {
        let texts = node.texts
        // A secure field is the one node worth printing with nothing to print: the fact that a
        // password field has focus is exactly what a describer should know.
        if texts.isEmpty && node.subrole != AXRoles.secureTextField && node.role != AXRoles.secureTextField {
            return nil
        }
        var line = String(repeating: "  ", count: indent) + "[\(node.role)]"
        if texts.isEmpty { return line }
        line += " " + texts.joined(separator: " | ")
        return line
    }

    /// Head + tail, cut on line boundaries so the outline is always whole lines.
    static func truncate(_ text: String, to maxChars: Int) -> String {
        guard text.count > maxChars, maxChars > 0 else { return text }
        let marker = "\n…\n"
        guard maxChars > marker.count else { return String(text.prefix(maxChars)) }
        let budget = maxChars - marker.count
        let headBudget = Int(Double(budget) * headShare)
        let tailBudget = budget - headBudget
        let head = cutAtLineBoundary(String(text.prefix(headBudget)), fromEnd: true)
        let tail = cutAtLineBoundary(String(text.suffix(tailBudget)), fromEnd: false)
        return head + marker + tail
    }

    private static func cutAtLineBoundary(_ piece: String, fromEnd: Bool) -> String {
        if fromEnd {
            guard let index = piece.lastIndex(of: "\n") else { return piece }
            return String(piece[piece.startIndex..<index])
        }
        guard let index = piece.firstIndex(of: "\n") else { return piece }
        return String(piece[piece.index(after: index)...])
    }

    /// SHA-256 of the outline, hex. #53 compares this tick's hash with the last one to decide
    /// whether the window's *content* changed, which pixels cannot answer.
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Small helpers

extension String {
    func truncated(to limit: Int) -> String {
        count <= limit ? self : String(prefix(limit))
    }
}
