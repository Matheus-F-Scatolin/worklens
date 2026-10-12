import Foundation
import Testing

@testable import WorklensCore

/// The channel a second launch and `worklens settings` use to reach the running app (#147).
/// Everything here is the part that can be wrong without anyone noticing: the name both ends
/// must agree on, the payload a distributed notification is allowed to carry, and what a
/// `--tab` argument is allowed to be.
@Suite("Settings reveal")
struct SettingsRevealTests {
    @Test("the notification name is keyed to the bundle identifier")
    func nameIsKeyedToBundle() {
        #expect(SettingsReveal.notificationName.rawValue.hasPrefix(Config.bundleIdentifier))
        #expect(SettingsReveal.notificationName.rawValue == "dev.worklens.app.show-settings")
    }

    @Test("the home request has its own name, so no Settings request is mistaken for it")
    func homeNameIsDistinct() {
        #expect(SettingsReveal.homeNotificationName.rawValue == "dev.worklens.app.show-home")
        #expect(SettingsReveal.homeNotificationName != SettingsReveal.notificationName)
    }

    @Test("no tab means an empty payload, which reads back as no preference")
    func noTabRoundTrips() {
        let info = SettingsReveal.userInfo(tab: nil)
        #expect(info.isEmpty)
        #expect(SettingsReveal.target(in: info) == nil)
        #expect(SettingsReveal.target(in: nil) == nil)
    }

    @Test("every section survives the round trip through the payload")
    func everySectionRoundTrips() {
        for section in SettingsSection.allCases {
            let info = SettingsReveal.userInfo(tab: section)
            #expect(info[SettingsReveal.tabKey] == section.rawValue)
            #expect(SettingsReveal.target(in: info) == SettingsTarget(section))
        }
    }

    @Test("the payload is property-list values only, since a distributed notification carries no more")
    func payloadIsPlistSafe() {
        let info = SettingsReveal.userInfo(tab: .capture)
        #expect(PropertyListSerialization.propertyList(info, isValidFor: .binary))
    }

    /// #286: an older build's second copy still posts the old pane names, and they land on the
    /// section that holds what those panes did.
    @Test("an old pane's name from an older sender still lands on its section")
    func oldPaneNamesStillLand() {
        #expect(SettingsReveal.target(in: [SettingsReveal.tabKey: "permissions"]) == SettingsTarget(.access))
        #expect(SettingsReveal.target(in: [SettingsReveal.tabKey: "cost"]) == SettingsTarget(.usage))
        #expect(SettingsReveal.target(in: [SettingsReveal.tabKey: "activity"])?.section == .general)
    }

    @Test("a name this build does not have is no preference, not a crash")
    func unknownPaneIsIgnored() {
        #expect(SettingsReveal.target(in: [SettingsReveal.tabKey: "chat"]) == nil)
        #expect(SettingsReveal.target(in: [SettingsReveal.tabKey: 7]) == nil)
        #expect(SettingsReveal.target(in: ["other": "general"]) == nil)
    }

    @Test("--tab matching ignores case and surrounding spaces")
    func tabNamesAreForgiving() {
        #expect(SettingsReveal.target(named: "general") == SettingsTarget(.general))
        #expect(SettingsReveal.target(named: "Privacy") == SettingsTarget(.privacy))
        #expect(SettingsReveal.target(named: "  USAGE ") == SettingsTarget(.usage))
        #expect(SettingsReveal.target(named: "Permissions") == SettingsTarget(.access))
        #expect(SettingsReveal.target(named: "") == nil)
        #expect(SettingsReveal.target(named: "models & budget") == nil)
    }

    @Test("the accepted names the CLI prints are the seven sections")
    func tabNamesAreTheSections() {
        #expect(SettingsReveal.tabNames == SettingsSection.allCases.map(\.rawValue))
        #expect(SettingsReveal.tabNames.count == 7)
        for name in SettingsReveal.tabNames {
            #expect(SettingsReveal.target(named: name) != nil)
        }
    }

    /// #147: `swift run Worklens settings` has to find an app started the same way, which has
    /// no bundle identifier for `runningApplications(withBundleIdentifier:)` to match on.
    @Test("a Worklens is recognised bundled or straight from a checkout")
    func recognisesBundledAndUnbundled() {
        #expect(SettingsReveal.isWorklens(
            bundleIdentifier: Config.bundleIdentifier, executableName: "Worklens"
        ))
        #expect(SettingsReveal.isWorklens(bundleIdentifier: nil, executableName: "Worklens"))
        #expect(!SettingsReveal.isWorklens(
            bundleIdentifier: "com.apple.finder", executableName: "Worklens"
        ))
        #expect(!SettingsReveal.isWorklens(bundleIdentifier: nil, executableName: "Xcode"))
        #expect(!SettingsReveal.isWorklens(bundleIdentifier: nil, executableName: nil))
    }

    // Delivery itself is not tested here: `DistributedNotificationCenter` goes through the
    // notification daemon and hands the block to the main queue, which a test run does not pump.
    // What both ends actually have to agree on — the name and the payload — is above.
}
