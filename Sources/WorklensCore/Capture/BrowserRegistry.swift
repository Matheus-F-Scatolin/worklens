import Foundation

/// The browsers Worklens knows how to read a URL from, and how to normalize what comes back.
///
/// One table, because the taxonomy (#7) needs the same "is this a browser?" answer and the same
/// title-suffix list that the collector uses.
public enum BrowserRegistry {
    /// How a browser exposes its front tab's URL.
    public enum URLSource: Sendable, Equatable {
        /// `get URL of active tab of front window` — the Chromium AppleScript dictionary.
        case chromiumAppleScript
        /// `get URL of front document` — Safari's dictionary.
        case safariAppleScript
        /// No scriptable URL (Firefox); the window title is all there is.
        case titleOnly
    }

    public struct Browser: Sendable, Equatable {
        public let bundleID: String
        public let urlSource: URLSource
        /// Suffixes the browser appends to the page title, longest-first, used when AppleScript
        /// is unavailable and as the only signal for Firefox.
        public let titleSuffixes: [String]
    }

    public static let browsers: [Browser] = [
        Browser(bundleID: "com.google.Chrome", urlSource: .chromiumAppleScript,
                titleSuffixes: [" - Google Chrome"]),
        Browser(bundleID: "com.google.Chrome.canary", urlSource: .chromiumAppleScript,
                titleSuffixes: [" - Google Chrome Canary", " - Google Chrome"]),
        Browser(bundleID: "com.brave.Browser", urlSource: .chromiumAppleScript,
                titleSuffixes: [" - Brave", " - Brave Browser"]),
        Browser(bundleID: "com.microsoft.edgemac", urlSource: .chromiumAppleScript,
                titleSuffixes: [" - Microsoft\u{200B} Edge", " - Microsoft Edge"]),
        Browser(bundleID: "company.thebrowser.Browser", urlSource: .chromiumAppleScript,
                titleSuffixes: [" — Arc", " - Arc"]),
        Browser(bundleID: "com.vivaldi.Vivaldi", urlSource: .chromiumAppleScript,
                titleSuffixes: [" - Vivaldi"]),
        Browser(bundleID: "com.apple.Safari", urlSource: .safariAppleScript, titleSuffixes: []),
        Browser(bundleID: "org.mozilla.firefox", urlSource: .titleOnly,
                titleSuffixes: [" — Mozilla Firefox", " - Mozilla Firefox"]),
        Browser(bundleID: "org.mozilla.firefoxdeveloperedition", urlSource: .titleOnly,
                titleSuffixes: [" — Firefox Developer Edition", " - Firefox Developer Edition"]),
    ]

    public static func browser(forBundleID bundleID: String?) -> Browser? {
        guard let bundleID else { return nil }
        return browsers.first { $0.bundleID == bundleID }
    }

    public static func isBrowser(_ bundleID: String?) -> Bool { browser(forBundleID: bundleID) != nil }

    /// The AppleScript that asks `bundleID` for its front tab's URL, or nil when it has none.
    public static func urlScript(for browser: Browser) -> String? {
        switch browser.urlSource {
        case .chromiumAppleScript:
            return "tell application id \"\(browser.bundleID)\" to get URL of active tab of front window"
        case .safariAppleScript:
            return "tell application id \"\(browser.bundleID)\" to get URL of front document"
        case .titleOnly:
            return nil
        }
    }

    /// Removes the browser's own name — and anything it appends after it — from a window title,
    /// leaving the page title.
    ///
    /// It cuts at the browser's name rather than trimming a suffix, because the name is not
    /// always last. A Chrome with more than one profile titles its windows
    /// `<page> - Google Chrome - <profile>`, and that is what `AXTitle` reports (#55);
    /// `kCGWindowName` happens to report the page title alone. Cutting makes the two readers
    /// agree, and keeps the profile name — which is a person's name — out of every row.
    ///
    /// The *last* occurrence wins, so a page whose own title contains the browser's name keeps
    /// as much of itself as possible.
    public static func strippedTitle(_ title: String?, bundleID: String?) -> String? {
        guard let title else { return nil }
        guard let browser = browser(forBundleID: bundleID) else { return title }
        // Cutting also makes the order of `titleSuffixes` moot: " - Google Chrome" and
        // " - Google Chrome Canary" start at the same place, so either one drops the same text.
        for suffix in browser.titleSuffixes {
            guard let cut = title.range(of: suffix, options: .backwards) else { continue }
            let stripped = String(title[title.startIndex..<cut.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : stripped
        }
        return title
    }

    // MARK: URL normalization

    public struct NormalizedURL: Sendable, Equatable {
        /// Scheme, host and path — plus the query only when the caller passed `storeQuery`.
        public let absolute: String
        /// Lowercased host, or nil for URLs that have none (`about:blank`, `file:///…`).
        public let host: String?
    }

    /// Strips the userinfo and the fragment always and the query unless `storeQuery`, and
    /// lowercases the host.
    ///
    /// Query strings are dropped by default because they carry access tokens, search terms and
    /// message ids — the things a timeline has no business remembering. The userinfo
    /// (`https://alice:hunter2@example.com/`) is a credential whenever it holds a password, so it
    /// is never kept.
    public static func normalize(_ raw: String?, storeQuery: Bool = false) -> NormalizedURL? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }

        components.fragment = nil
        components.user = nil
        components.password = nil
        if !storeQuery { components.query = nil }
        if let host = components.host { components.host = host.lowercased() }
        components.scheme = components.scheme?.lowercased()

        guard let absolute = components.string, !absolute.isEmpty else { return nil }
        let host = components.host.map { $0.lowercased() }
        return NormalizedURL(absolute: absolute, host: host?.isEmpty == true ? nil : host)
    }

    /// What `ax_snapshots.document_url` may hold for a window's `AXDocument` (#311).
    ///
    /// On a browser window `AXDocument` is the tab's address, so it gets `browser_url`'s rule:
    /// through `normalize` (no query, no fragment, lowercased scheme and host), and nothing at all
    /// for a page while `COLLECT_BROWSER_URL` is off. A page is any window of a known browser, or
    /// any http(s) address whatever app reported it. Anything else — a `file:` in an editor — is
    /// normalized and kept. A value `normalize` cannot read is dropped, never stored raw.
    public static func storableDocumentURL(
        _ raw: String?, bundleID: String?, collectBrowserURL: Bool
    ) -> String? {
        guard let normalized = normalize(raw) else { return nil }
        if !collectBrowserURL {
            let scheme = URLComponents(string: normalized.absolute)?.scheme
            if isBrowser(bundleID) || scheme == "http" || scheme == "https" { return nil }
        }
        return normalized.absolute
    }
}
