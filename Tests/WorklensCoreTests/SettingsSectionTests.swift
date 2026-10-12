import Foundation
import Testing

@testable import WorklensCore

/// Settings inside the reader (#286). The page is SwiftUI in the `Worklens` target, which has no
/// tests, so the list it is built from lives here: the order, the words, and — the one that can
/// actually break a user — where every name the old window used still lands.
@Suite("Settings sections")
struct SettingsSectionTests {
    @Test("six sections, then Advanced, in list order")
    func order() {
        #expect(SettingsSection.allCases.map(\.rawValue) == [
            "general", "capture", "privacy", "log", "connections", "usage", "advanced",
        ])
        #expect(SettingsSection.primary == Array(SettingsSection.allCases.dropLast()))
        #expect(!SettingsSection.primary.contains(.advanced))
    }

    @Test("titles are distinct and sentence case")
    func titles() {
        let titles = SettingsSection.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(SettingsSection.connections.title == "Connections")
        #expect(SettingsSection.usage.title == "Usage")
        for title in titles {
            #expect(title.first?.isUppercase == true)
            #expect(title.dropFirst().allSatisfy { !$0.isUppercase })
        }
    }

    /// The acceptance line: no old value is left unmapped. `settings_tab` in `app_state`, a shell
    /// history's `--tab`, and an older build's `SettingsReveal` all still carry these.
    @Test("every old pane name maps to a section")
    func everyLegacyValueMaps() {
        #expect(SettingsSection.legacyValues.count == 11)
        for raw in SettingsSection.legacyValues {
            #expect(SettingsSection.target(named: raw) != nil, "\(raw) no longer lands anywhere")
            #expect(SettingsSection.restoring(raw) != nil, "\(raw) no longer restores")
        }
    }

    @Test("the old panes land where their contents went")
    func legacyMapping() {
        #expect(SettingsSection.target(named: "cost") == SettingsTarget(.usage))
        #expect(SettingsSection.target(named: "permissions") == SettingsTarget(.capture, anchor: .access))
        #expect(SettingsSection.target(named: "projects") == SettingsTarget(.log, anchor: .projects))
        // Reports was the section's name until the cut (2026-10-05): a stored value still lands.
        #expect(SettingsSection.target(named: "reports") == SettingsTarget(.log, anchor: .projects))
        #expect(SettingsSection.restoring("reports") == .log)
        #expect(SettingsSection.target(named: "integrations")?.section == .connections)
        #expect(SettingsSection.target(named: "assistant")?.section == .connections)
        #expect(SettingsSection.target(named: "activity")?.section == .general)
        // The four that kept their names keep their sections, with no row to light.
        for kept in ["general", "capture", "privacy", "advanced"] {
            #expect(SettingsSection.target(named: kept) == SettingsTarget(SettingsSection(rawValue: kept)!))
        }
    }

    @Test("a name no build ever wrote is nil, not General")
    func unknownIsNil() {
        #expect(SettingsSection.target(named: "models") == nil)
        #expect(SettingsSection.target(named: "claude") == nil)
        #expect(SettingsSection.restoring("") == nil)
    }

    @Test("every section's own name round-trips")
    func rawValuesRoundTrip() {
        for section in SettingsSection.allCases {
            #expect(SettingsSection.restoring(section.rawValue) == section)
        }
    }

    @Test("an anchor names the section it is on")
    func anchorsBelongToASection() {
        #expect(SettingsTarget(.access) == SettingsTarget(.capture, anchor: .access))
        #expect(SettingsAnchor.providers.section == .connections)
        #expect(SettingsAnchor.status.section == .general)
        for anchor in SettingsAnchor.allCases {
            #expect(SettingsTarget(anchor).section == anchor.section)
        }
    }
}
