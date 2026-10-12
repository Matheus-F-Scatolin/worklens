import Foundation
import Testing
@testable import WorklensCore

/// #145: what the menu says while the policy is easing off, so a five-minute cadence is never
/// mistaken for a fault.
@Suite("Menu battery line")
struct MenuBatteryLineTests {
    private func menu(
        _ power: PowerState,
        mode: BatteryCaptureMode = .slow,
        scheduler: SchedulerState = .running,
        interval: Int = 60,
        meeting: Bool = false
    ) -> MenuModel {
        MenuModel(
            state: MenuState(
                scheduler: scheduler,
                captureIntervalSeconds: interval,
                meetingIntervalSeconds: 300,
                inMeeting: meeting,
                power: power,
                batteryMode: mode
            ),
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    @Test("On battery the status row names the reason and the cadence")
    func onBattery() {
        #expect(menu(PowerState(onBattery: true)).statusLine
            == "On battery · capturing every 5 min")
    }

    @Test("`describe-later` says describing is waiting for the charger")
    func describeLater() {
        #expect(menu(PowerState(onBattery: true), mode: .describeLater).statusLine
            == "On battery · capturing every 5 min · describing when plugged in")
    }

    @Test("Low Power Mode is named, because switching it off is the answer")
    func lowPowerMode() {
        #expect(menu(PowerState(lowPowerMode: true)).statusLine
            == "Low Power Mode · capturing every 5 min")
    }

    @Test("On mains, and under `normal`, the row is the one it always was")
    func unchanged() {
        #expect(menu(.mains).statusLine == "Capturing · every 60 s")
        #expect(menu(PowerState(onBattery: true), mode: .normal).statusLine
            == "Capturing · every 60 s")
    }

    @Test("It stays a statement: nothing here is a problem row")
    func notAProblem() {
        let menu = menu(PowerState(onBattery: true))
        #expect(menu.statusRow.kind == .status)
        #expect(menu.icon == .capturing)
        #expect(menu.degraded == nil)
    }

    @Test("Paused beats the battery: the battery is not why nothing is being captured")
    func pausedWins() {
        #expect(menu(PowerState(onBattery: true), scheduler: .paused(until: nil)).statusLine
            == "Paused until you resume")
    }

    @Test("The meeting cadence is stretched too, and the row says the real number")
    func meetingCadence() {
        #expect(menu(PowerState(onBattery: true), meeting: true).statusLine
            == "On battery · capturing every 25 min")
    }

    @Test("VoiceOver hears the same fact, spelled for speech")
    func spokenLabel() {
        #expect(menu(PowerState(onBattery: true)).iconLabel
            == "Worklens, on battery, capturing every 5 minutes")
        #expect(menu(PowerState(onBattery: true), mode: .describeLater).iconLabel
            == "Worklens, on battery, capturing every 5 minutes, describing when plugged in")
    }
}
