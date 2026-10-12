import Foundation

/// Privacy's one "Never look at" list (#286): the three blocklists — apps, sites and window
/// titles — as one mixed list with a type chip on each row, and one field that guesses which of
/// the three you are typing. It still writes the three keys it always did; nothing about how an
/// entry matches changes.
public enum NeverLookAt {
    /// An installed app the field can match by name: what Finder calls it, and the identifier the
    /// blocklist stores.
    public struct App: Sendable, Equatable {
        public let name: String
        public let bundleID: String

        public init(name: String, bundleID: String) {
            self.name = name
            self.bundleID = bundleID
        }
    }

    /// What typing `text` would add: the list it goes on and the value written to it.
    public struct Guess: Sendable, Equatable {
        public let list: Blocklist
        public let value: String
        /// The installed app it matched by name, when it did — shown as that name on the row.
        public let appName: String?

        public init(list: Blocklist, value: String, appName: String? = nil) {
            self.list = list
            self.value = value
            self.appName = appName
        }
    }

    /// The chip on a row, and on the field while you type.
    public static func chip(_ list: Blocklist) -> String {
        switch list {
        case .apps: return L10n.string("App")
        case .sites: return L10n.string("Site")
        case .titles: return L10n.string("Window title")
        }
    }

    /// Which list `text` belongs on, in this order:
    ///
    /// 1. an installed app's name, matched without regard to case → that app's identifier;
    /// 2. a bundle identifier — reverse DNS whose last part is not a web domain ending, like
    ///    `com.apple.Safari` → the apps list, as typed;
    /// 3. a host, or an address with a scheme or a path — `bank.com`, `https://mail.google.com/x`
    ///    → the sites list, as its host;
    /// 4. anything else — a word, a phrase — → the window titles list, as typed.
    ///
    /// An empty field guesses App, which is what the chip shows before you type.
    public static func guess(_ text: String, apps: [App] = []) -> Guess {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return Guess(list: .apps, value: "") }
        if let app = apps.first(where: { $0.name.caseInsensitiveCompare(typed) == .orderedSame }) {
            return Guess(list: .apps, value: app.bundleID, appName: app.name)
        }
        if let host = host(in: typed) {
            let labels = host.split(separator: ".").map(String.init)
            if !hadWebShape(typed), isBundleIdentifier(labels) {
                return Guess(list: .apps, value: typed)
            }
            return Guess(list: .sites, value: host)
        }
        return Guess(list: .titles, value: typed)
    }

    /// The host `text` names, when it is shaped like one: dot-separated labels of letters, digits
    /// and hyphens, optionally with a scheme in front and a path, query or port after.
    static func host(in text: String) -> String? {
        guard !text.contains(" ") else { return nil }
        var rest = text
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        if let end = rest.firstIndex(where: { "/?#:".contains($0) }) { rest = String(rest[..<end]) }
        let labels = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        for label in labels {
            guard !label.isEmpty, label.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        }
        // `3.5` is a number, not a host.
        guard labels.contains(where: { $0.contains(where: \.isLetter) }) else { return nil }
        return rest
    }

    /// A scheme or a path is only ever typed for a web address.
    static func hadWebShape(_ text: String) -> Bool {
        text.contains("://") || text.contains("/")
    }

    /// `com.apple.Safari`, `org.mozilla.firefox`, `com.1password.1password`: at least three parts,
    /// the first a reverse-DNS root, and the last not a web domain ending. `app.nubank.com.br`
    /// ends in one, so it is a site even though `app` is also a root.
    static func isBundleIdentifier(_ labels: [String]) -> Bool {
        guard labels.count >= 3, let first = labels.first?.lowercased(), let last = labels.last?.lowercased()
        else { return false }
        guard reverseDNSRoots.contains(first) else { return false }
        return !isWebEnding(last)
    }

    static func isWebEnding(_ label: String) -> Bool {
        // Every country code is two letters, and no bundle identifier ends in a two-letter part.
        if label.count == 2, label.allSatisfy(\.isLetter) { return true }
        return webEndings.contains(label)
    }

    static let reverseDNSRoots: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "co", "me", "ai", "us", "de", "uk", "fr", "br",
        "info", "edu", "gov", "tv", "cc", "ch", "nl", "se", "jp", "ru", "cn", "au", "ca",
    ]

    static let webEndings: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "ai", "info", "edu", "gov", "tv", "cc", "co", "me",
        "biz", "xyz", "site", "online", "tech", "cloud", "page", "blog", "shop", "store", "news",
    ]
}

extension NeverLookAt {
    /// The inline confirm on Privacy's "Delete a date range":
    /// `Delete 4,312 screenshots from 1–7 Sep?`. The count is the one the eraser will delete —
    /// `DataEraser.count(from:to:)` over the same range — never an estimate.
    public static func deleteQuestion(
        count: Int, from: Date, to: Date, now: Date = Date(), timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let range = Format.dayRange(from: from, to: to, now: now, timeZone: timeZone, locale: locale)
        return count == 1
            ? L10n.format("Delete 1 screenshot from %@?", range)
            : L10n.format("Delete %@ screenshots from %@?", Format.count(count, locale: locale), range)
    }

    /// What the row says when the range holds nothing to delete.
    public static func nothingToDelete(
        from: Date, to: Date, now: Date = Date(), timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        L10n.format(
            "Nothing was captured on %@.",
            Format.dayRange(from: from, to: to, now: now, timeZone: timeZone, locale: locale)
        )
    }
}
