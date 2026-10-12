import Foundation

/// What Worklens is allowed to do with the frame in front of it.
///
/// `redact` is not a silent skip: the tick still writes a row, so the timeline shows honest
/// elapsed time, but the row carries no image and no title or URL. `reason` is exactly what
/// lands in `captures.skip_reason`, which is why it round-trips through `SkipReason`.
public enum PrivacyDecision: Equatable, Sendable {
    case allow
    case redact(reason: String)

    /// The `skip_reason` this decision writes, or nil when nothing was blocked.
    public var skipReason: SkipReason? {
        guard case let .redact(reason) = self else { return nil }
        // An unrecognised refinement still reads as "blocked" rather than as nothing at all.
        return SkipReason(rawValue: reason) ?? .blocked
    }

    public var isRedacted: Bool { self != .allow }
}

/// The apps, windows and sites Worklens must never look at, and the one place that decision is
/// made. Moved here from `Capture/Blocklist.swift` in #16, which added hosts and the reason.
///
/// Three lists, checked in this order — the earliest match wins, so the reason a frame was
/// dropped is the strongest thing true about it:
///
/// 1. `BLOCKED_BUNDLE_IDS` — exact bundle identifier.
/// 2. `BLOCKED_TITLE_PATTERNS` — case-insensitive regexes, tested against the window title *and*
///    the URL, because a page title and its address leak the same thing.
/// 3. `BLOCKED_URL_HOSTS` — suffix match on the frontmost tab's host at a dot boundary, so
///    `nubank.com.br` covers `app.nubank.com.br` and does not cover `notnubank.com.br`.
public struct PrivacyPolicy: Sendable {
    public let bundleIDs: Set<String>
    /// Patterns that failed to compile are dropped, with the raw source kept for the log — a typo
    /// in one pattern must not silently disable the rest.
    private let patterns: [NSRegularExpression]
    public let invalidPatterns: [String]
    /// Normalised: lowercased, no scheme, no path, no leading dot.
    public let urlHosts: [String]

    /// The `skip_reason` values a redaction can carry.
    public static let bundleReason = SkipReason.blockedBundle.rawValue
    public static let titleReason = SkipReason.blockedTitle.rawValue
    public static let hostReason = SkipReason.blockedHost.rawValue
    /// Not a list match: a browser whose host could not be read while host exclusions are set.
    public static let hostUnknownReason = SkipReason.blockedHostUnknown.rawValue

    public init(bundleIDs: [String], titlePatterns: [String], urlHosts: [String] = []) {
        self.bundleIDs = Set(bundleIDs)

        var compiled: [NSRegularExpression] = []
        var invalid: [String] = []
        for source in titlePatterns {
            if let regex = try? NSRegularExpression(pattern: source, options: [.caseInsensitive]) {
                compiled.append(regex)
            } else {
                invalid.append(source)
            }
        }
        self.patterns = compiled
        self.invalidPatterns = invalid
        self.urlHosts = urlHosts.compactMap(PrivacyPolicy.normalizeHost)
    }

    public init(config: Config) {
        self.init(
            bundleIDs: config.blockedBundleIDs,
            titlePatterns: config.blockedTitlePatterns,
            urlHosts: config.blockedURLHosts
        )
    }

    // MARK: Deciding

    /// The decision for one frame. On top of the three lists, a fourth rule: with
    /// `BLOCKED_URL_HOSTS` set, a browser whose address could not be read is blocked too, because
    /// "no host" there means "could not check", not "not a blocked site" (security finding #4).
    /// The string overload below has no such rule — it is what the app-switch recorder asks, and
    /// that one never sees a page.
    public func decision(for context: ForegroundContext) -> PrivacyDecision {
        let listed = decision(
            bundleID: context.bundleID,
            windowTitle: context.windowTitle,
            browserURL: context.browserURL,
            // The stored host when there is one, else the one read for this check alone.
            urlHost: context.urlHost ?? context.policySite?.host
        )
        if listed == .allow, !urlHosts.isEmpty, context.urlHost == nil,
           context.policySite == .unreadable {
            return .redact(reason: PrivacyPolicy.hostUnknownReason)
        }
        return listed
    }

    public func decision(
        bundleID: String?,
        windowTitle: String?,
        browserURL: String?,
        urlHost: String? = nil
    ) -> PrivacyDecision {
        if let bundleID, bundleIDs.contains(bundleID) {
            return .redact(reason: PrivacyPolicy.bundleReason)
        }
        if matchesPattern(windowTitle) || matchesPattern(browserURL) {
            return .redact(reason: PrivacyPolicy.titleReason)
        }
        // `urlHost` is what the collector parsed; falling back to the URL covers the callers
        // (and the tests) that only have the address.
        let host = urlHost.flatMap(PrivacyPolicy.normalizeHost)
            ?? browserURL.flatMap(PrivacyPolicy.host(ofURL:))
        if let host, urlHosts.contains(where: { PrivacyPolicy.host(host, matches: $0) }) {
            return .redact(reason: PrivacyPolicy.hostReason)
        }
        return .allow
    }

    /// Kept for the callers that only need the yes/no.
    public func isBlocked(_ context: ForegroundContext) -> Bool {
        decision(for: context).isRedacted
    }

    // MARK: Host matching

    /// A host is blocked by `blocked` when it is that host or a subdomain of it. The dot
    /// boundary is the whole point: `evil-example.com` must not match `example.com`.
    static func host(_ host: String, matches blocked: String) -> Bool {
        host == blocked || host.hasSuffix(".\(blocked)")
    }

    /// Accepts what a person actually types into `.env`: a bare host, a host with a port, or a
    /// whole URL pasted out of the address bar. Returns nil for something with no host in it.
    static func normalizeHost(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        if text.contains("://"), let parsed = host(ofURL: text) { return parsed }
        text = String(text.prefix(while: { $0 != "/" }))
        if let colon = text.firstIndex(of: ":") { text = String(text[text.startIndex..<colon]) }
        while text.hasPrefix(".") { text.removeFirst() }
        while text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    static func host(ofURL url: String) -> String? {
        guard let host = URLComponents(string: url)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host
    }

    private func matchesPattern(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return patterns.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }
}
