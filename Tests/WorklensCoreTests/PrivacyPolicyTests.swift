import Foundation
import Testing
@testable import WorklensCore

/// #16 moved blocklist matching out of `Capture/Blocklist.swift` and gave it a reason, so these
/// are the old `BlocklistTests` plus the host list and the precedence order.
@Suite("PrivacyPolicy")
struct PrivacyPolicyTests {
    private let policy = PrivacyPolicy(
        bundleIDs: Config.defaultBlockedBundleIDs,
        titlePatterns: Config.defaultBlockedTitlePatterns,
        urlHosts: ["bankofamerica.com", "nubank.com.br", "healthcare.gov"]
    )

    private func decide(bundle: String? = nil, title: String? = nil, url: String? = nil) -> PrivacyDecision {
        policy.decision(bundleID: bundle, windowTitle: title, browserURL: url)
    }

    @Test("blocked bundle ids match exactly, not by prefix")
    func bundleIDs() {
        #expect(decide(bundle: "com.1password.1password") == .redact(reason: "blocked:bundle"))
        #expect(decide(bundle: "com.apple.keychainaccess") == .redact(reason: "blocked:bundle"))
        #expect(decide(bundle: "com.1password.1password-helper") == .allow)
        #expect(decide(bundle: "com.apple.Terminal") == .allow)
        #expect(decide() == .allow)
    }

    @Test("title patterns are case-insensitive and match anywhere in the title")
    func titlePatterns() {
        #expect(decide(bundle: "com.apple.Safari", title: "Bank — Private Browsing")
            == .redact(reason: "blocked:title"))
        #expect(decide(bundle: "com.google.Chrome", title: "gmail (incognito)")
            == .redact(reason: "blocked:title"))
        #expect(decide(bundle: "com.apple.Safari", title: "Reset your password")
            == .redact(reason: "blocked:title"))
        #expect(decide(bundle: "com.apple.Safari", title: "Swift docs") == .allow)
    }

    @Test("the URL is tested against the title patterns too")
    func urlPatterns() {
        #expect(decide(
            bundle: "com.google.Chrome", title: "Account",
            url: "https://example.com/password/reset"
        ) == .redact(reason: "blocked:title"))
    }

    @Test("a blocked host covers its subdomains and nothing that merely ends the same way")
    func hosts() {
        #expect(decide(bundle: "com.google.Chrome", title: "Accounts", url: "https://bankofamerica.com/")
            == .redact(reason: "blocked:host"))
        #expect(decide(bundle: "com.google.Chrome", title: "Accounts", url: "https://app.nubank.com.br/bills")
            == .redact(reason: "blocked:host"))
        #expect(decide(bundle: "com.google.Chrome", title: "Plans", url: "https://www.healthcare.gov/see-plans")
            == .redact(reason: "blocked:host"))
        // The dot boundary is the point: this is a different company.
        #expect(decide(bundle: "com.google.Chrome", title: "Blog", url: "https://notnubank.com.br/") == .allow)
        #expect(decide(bundle: "com.google.Chrome", title: "Docs", url: "https://swift.org/") == .allow)
    }

    @Test("the host is taken from urlHost when the collector parsed one")
    func hostFromField() {
        #expect(policy.decision(
            bundleID: "com.google.Chrome", windowTitle: "Accounts",
            browserURL: nil, urlHost: "app.bankofamerica.com"
        ) == .redact(reason: "blocked:host"))
    }

    /// The reason a frame was dropped should be the strongest thing true about it, so the order
    /// is bundle, then title, then host — and a page that trips two lists reports the first.
    @Test("bundle beats title beats host")
    func precedence() {
        #expect(decide(
            bundle: "com.1password.1password", title: "Private Browsing",
            url: "https://bankofamerica.com/"
        ) == .redact(reason: "blocked:bundle"))
        #expect(decide(
            bundle: "com.google.Chrome", title: "Private Browsing",
            url: "https://bankofamerica.com/"
        ) == .redact(reason: "blocked:title"))
    }

    @Test("every reason round-trips into the skip_reason column")
    func reasonsAreSkipReasons() {
        #expect(decide(bundle: "com.1password.1password").skipReason == .blockedBundle)
        #expect(decide(title: "Incognito").skipReason == .blockedTitle)
        #expect(decide(url: "https://healthcare.gov/x").skipReason == .blockedHost)
        #expect(PrivacyDecision.allow.skipReason == nil)
        // Everything a redaction can carry reads as "blocked" to a caller that only asks that.
        for reason in [SkipReason.blocked, .blockedBundle, .blockedTitle, .blockedHost] {
            #expect(reason.isBlocked)
        }
        for reason in [SkipReason.unchanged, .idle, .locked, .budget] {
            #expect(!reason.isBlocked)
        }
    }

    @Test("a pattern that will not compile is dropped, and the rest keep working")
    func invalidPattern() {
        let broken = PrivacyPolicy(bundleIDs: [], titlePatterns: ["Private Browsing", "([unclosed"])
        #expect(broken.invalidPatterns == ["([unclosed"])
        #expect(broken.decision(bundleID: nil, windowTitle: "x Private Browsing", browserURL: nil)
            == .redact(reason: "blocked:title"))
    }

    /// `.env` is typed by a person, not generated, so a pasted URL or a port has to work.
    @Test("host entries are normalised the way people actually write them")
    func hostNormalisation() {
        #expect(PrivacyPolicy.normalizeHost("  Bank.Example.COM  ") == "bank.example.com")
        #expect(PrivacyPolicy.normalizeHost("https://bank.example.com/login?x=1") == "bank.example.com")
        #expect(PrivacyPolicy.normalizeHost("bank.example.com:8443") == "bank.example.com")
        #expect(PrivacyPolicy.normalizeHost(".bank.example.com.") == "bank.example.com")
        #expect(PrivacyPolicy.normalizeHost("   ") == nil)

        let pasted = PrivacyPolicy(
            bundleIDs: [], titlePatterns: [], urlHosts: ["https://bank.example.com/login"]
        )
        #expect(pasted.decision(bundleID: nil, windowTitle: nil, browserURL: "https://bank.example.com/x")
            == .redact(reason: "blocked:host"))
    }

    @Test("an empty host list blocks nothing")
    func emptyHosts() {
        let bare = PrivacyPolicy(bundleIDs: [], titlePatterns: [], urlHosts: [])
        #expect(bare.decision(bundleID: "com.google.Chrome", windowTitle: "Bank", browserURL: "https://bankofamerica.com")
            == .allow)
    }

    @Test("Config reads BLOCKED_URL_HOSTS as a semicolon-separated list")
    func configParsing() throws {
        let config = try Config.load(
            layers: [["BLOCKED_URL_HOSTS": "bankofamerica.com; nubank.com.br ;healthcare.gov"]],
            cwd: FileManager.default.temporaryDirectory
        )
        #expect(config.blockedURLHosts == ["bankofamerica.com", "nubank.com.br", "healthcare.gov"])
        #expect(Config.defaults().blockedURLHosts.isEmpty)
    }
}
