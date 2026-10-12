import Foundation
import Testing
@testable import WorklensCore

@Suite("Blocklists (#128)")
struct BlocklistsTests {
    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-blocklists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Validation

    @Test("a site is accepted however it was pasted, and refused when it has no host")
    func siteValidation() throws {
        #expect(try Blocklist.sites.normalize(" https://App.Nubank.com.BR/login?x=1 ") == "app.nubank.com.br")
        #expect(try Blocklist.sites.normalize("nubank.com.br:443") == "nubank.com.br")
        #expect(throws: BlocklistError.notAHost("/just/a/path")) {
            try Blocklist.sites.normalize("/just/a/path")
        }
        #expect(throws: BlocklistError.empty(.sites)) { try Blocklist.sites.normalize("   ") }
    }

    @Test("a window title is a regex, so one that cannot compile is refused where it is typed")
    func titleValidation() throws {
        #expect(try Blocklist.titles.normalize("  Private Browsing ") == "Private Browsing")
        // A real pattern, not a literal: this is what PRIVACY.md promises the list is.
        #expect(try Blocklist.titles.normalize("(Incognito|InPrivate)") == "(Incognito|InPrivate)")
        #expect(throws: BlocklistError.notARegex("(unclosed")) {
            try Blocklist.titles.normalize("(unclosed")
        }
    }

    @Test("an app is a bundle identifier, and the error points at the picker")
    func appValidation() throws {
        #expect(try Blocklist.apps.normalize(" com.apple.Safari ") == "com.apple.Safari")
        #expect(throws: BlocklistError.notABundleID("Safari")) { try Blocklist.apps.normalize("Safari") }
        #expect(throws: BlocklistError.notABundleID("/Applications/Safari.app")) {
            try Blocklist.apps.normalize("/Applications/Safari.app")
        }
        #expect(BlocklistError.notABundleID("Safari").description.contains("com.apple.Safari"))
    }

    // MARK: The overlay

    @Test("the effective list is (defaults ∪ .env ∪ added) − removed")
    func effectiveList() {
        let base = Config.defaultBlockedBundleIDs
        var overlay = BlocklistOverlay()
        overlay.block("com.acme.bank", in: .apps)
        overlay.unblock("com.1password.1password", in: .apps, base: base)

        #expect(overlay.effective(.apps, base: base) == ["com.apple.keychainaccess", "com.acme.bank"])
        // A built-in really can be taken off — the whole reason the overlay stores removals.
        #expect(!overlay.effective(.apps, base: base).contains("com.1password.1password"))
        // Undoing that removal puts it back where `.env` and the defaults had it.
        overlay.restore("com.1password.1password", in: .apps)
        #expect(overlay.effective(.apps, base: base) == base + ["com.acme.bank"])
    }

    @Test("adding twice adds once, and a removal matches however the lower layer spelled the host")
    func canonicalComparison() {
        var overlay = BlocklistOverlay()
        overlay.block("nubank.com.br", in: .sites)
        overlay.block("NuBank.com.br", in: .sites)
        #expect(overlay.additions(to: .sites) == ["nubank.com.br"])

        // The `.env` below spelled it as a pasted URL; removing the host still removes it, and
        // what you added is all that is left.
        overlay.unblock("clinic.example", in: .sites, base: ["https://Clinic.Example/patients"])
        #expect(overlay.effective(.sites, base: ["https://Clinic.Example/patients"]) == ["nubank.com.br"])
    }

    @Test("blocking something you had removed makes it blocked again, and vice versa")
    func blockAndUnblockAreOpposites() {
        var overlay = BlocklistOverlay()
        overlay.unblock("com.1password.1password", in: .apps, base: Config.defaultBlockedBundleIDs)
        #expect(overlay.removals(from: .apps) == ["com.1password.1password"])
        overlay.block("com.1password.1password", in: .apps)
        #expect(overlay.removals(from: .apps).isEmpty)
        #expect(overlay.additions(to: .apps) == ["com.1password.1password"])
        #expect(!overlay.isEmpty)
        #expect(BlocklistOverlay().isEmpty)
    }

    @Test("taking back something only you added leaves no tombstone behind")
    func removingYourOwnEntryLeavesNothing() {
        var overlay = BlocklistOverlay()
        overlay.block("com.acme.bank", in: .apps)
        overlay.unblock("com.acme.bank", in: .apps, base: Config.defaultBlockedBundleIDs)
        #expect(overlay.additions(to: .apps).isEmpty)
        // Nothing underneath supplies it, so there is nothing to remember having removed — the
        // Settings window would otherwise show a struck-through row for ever.
        #expect(overlay.removals(from: .apps).isEmpty)
        #expect(overlay.isEmpty)
    }

    // MARK: The file

    @Test("a change survives a round trip, and the file is 0600")
    func storeRoundTrip() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlocklistStore(url: dir.appendingPathComponent("blocklists.json"))

        #expect(store.load().isEmpty)
        #expect(try store.block("https://app.nubank.com.br/login", in: .sites) == "app.nubank.com.br")
        try store.unblock("com.1password.1password", in: .apps, base: Config.defaultBlockedBundleIDs)

        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)

        let reread = BlocklistStore(url: store.url).load()
        #expect(reread.additions(to: .sites) == ["app.nubank.com.br"])
        #expect(reread.removals(from: .apps) == ["com.1password.1password"])
    }

    @Test("an entry that does not validate never reaches the file")
    func storeValidatesFirst() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlocklistStore(url: dir.appendingPathComponent("blocklists.json"))

        #expect(throws: BlocklistError.notARegex("[unclosed")) {
            try store.block("[unclosed", in: .titles)
        }
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test("a pattern .env wrote that does not compile can still be removed")
    func storeRemovesAnUnparseableEntry() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlocklistStore(url: dir.appendingPathComponent("blocklists.json"))

        // `Config` keeps an unparseable `BLOCKED_TITLE_PATTERNS` entry — only `PrivacyPolicy`
        // drops it, with a warning — so Settings → Privacy draws a row with a "−" on it. The
        // "−" has to work, which it cannot if removal re-validates what it is removing.
        #expect(try store.unblock("(unclosed", in: .titles, base: ["(unclosed", "Private Browsing"])
            == "(unclosed")
        #expect(store.load().removals(from: .titles) == ["(unclosed"])
        #expect(store.load().effective(.titles, base: ["(unclosed", "Private Browsing"])
            == ["Private Browsing"])

        // And the removal can be undone the same way.
        try store.restore("(unclosed", in: .titles)
        #expect(store.load().removals(from: .titles).isEmpty)
    }

    @Test("a host .env spelled in a way `normalizeHost` refuses can still be removed")
    func storeRemovesAnUnparseableHost() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlocklistStore(url: dir.appendingPathComponent("blocklists.json"))

        try store.unblock("not a host", in: .sites, base: ["not a host"])
        #expect(store.load().effective(.sites, base: ["not a host"]).isEmpty)
    }

    @Test("a corrupt file reads as no changes rather than as no blocklists")
    func corruptFileIsIgnored() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("blocklists.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(BlocklistStore(url: url).load().isEmpty)
    }

    // MARK: The seam

    @Test("every load folds the overlay into the three lists, over .env and over the defaults")
    func loadAppliesTheOverlay() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "BLOCKED_URL_HOSTS=bank.example;clinic.example\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let settings = dir.appendingPathComponent("settings.json")
        let store = BlocklistStore(url: BlocklistStore.url(besideSettings: settings))
        try store.block("app.nubank.com.br", in: .sites)
        try store.unblock("clinic.example", in: .sites, base: ["bank.example", "clinic.example"])
        try store.unblock("com.1password.1password", in: .apps, base: Config.defaultBlockedBundleIDs)

        let config = try Config.load(
            environment: [:],
            cwd: dir,
            appSupportEnv: dir.appendingPathComponent("absent.env"),
            settingsFile: settings
        )

        #expect(config.blockedURLHosts == ["bank.example", "app.nubank.com.br"])
        #expect(config.blockedBundleIDs == ["com.apple.keychainaccess"])
        // And the decision every capture goes through agrees, because it reads the same `Config`.
        let policy = PrivacyPolicy(config: config)
        #expect(policy.decision(bundleID: nil, windowTitle: nil, browserURL: nil, urlHost: "app.nubank.com.br")
            .isRedacted)
        #expect(!policy.decision(bundleID: "com.1password.1password", windowTitle: nil, browserURL: nil)
            .isRedacted)
        #expect(!policy.decision(bundleID: nil, windowTitle: nil, browserURL: nil, urlHost: "clinic.example")
            .isRedacted)
    }

    @Test("the overlay lives beside the settings file, so a scratch settings path never reads the real one")
    func overlaySitsBesideSettings() {
        #expect(BlocklistStore.defaultURL == BlocklistStore.url(besideSettings: SettingsStore.defaultURL))
        #expect(BlocklistStore.defaultURL.lastPathComponent == "blocklists.json")
        #expect(BlocklistStore.url(besideSettings: URL(fileURLWithPath: "/tmp/x/settings.json"))
            == URL(fileURLWithPath: "/tmp/x/blocklists.json"))
    }

    // MARK: Rows

    @Test("each row says which layer put it there")
    func rowSources() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "BLOCKED_URL_HOSTS=bank.example\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let settings = dir.appendingPathComponent("settings.json")
        let store = BlocklistStore(url: BlocklistStore.url(besideSettings: settings))
        try store.block("app.nubank.com.br", in: .sites)
        try store.block("com.acme.bank", in: .apps)

        let loaded = try Config.loadWithProvenance(
            environment: [:],
            cwd: dir,
            appSupportEnv: dir.appendingPathComponent("absent.env"),
            settingsFile: settings
        )
        let overlay = store.load()

        let sites = Blocklist.sites.rows(
            config: loaded.config, overlay: overlay, provenance: loaded.provenance
        )
        #expect(sites.map(\.value) == ["bank.example", "app.nubank.com.br"])
        #expect(sites.map(\.source) == [.file(.cwd), .app])
        #expect(sites.map(\.source.label) == [".env", "yours"])

        // Nothing set BLOCKED_BUNDLE_IDS, so the two that came with Worklens say so.
        let apps = Blocklist.apps.rows(
            config: loaded.config, overlay: overlay, provenance: loaded.provenance
        )
        #expect(apps.map(\.source) == [.builtIn, .builtIn, .app])
        // Blocking something `.env` already blocks does not relabel that row as yours: removing
        // it still has to leave a tombstone, and the row has to say so.
        try store.block("bank.example", in: .sites)
        let relabelled = Blocklist.sites.rows(
            config: loaded.config, overlay: store.load(), provenance: loaded.provenance
        )
        #expect(relabelled.first?.source == .file(.cwd))
        #expect(apps.last?.value == "com.acme.bank")
        #expect(apps.first?.source.isYours == false)
    }
}
