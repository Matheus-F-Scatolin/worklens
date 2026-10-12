import Foundation
import Testing
@testable import WorklensCore

/// #145: the battery decision, which is the whole policy once the OS facts are in hand.
@Suite("Power policy")
struct PowerPolicyTests {
    @Test("On mains nothing changes, whatever the setting", arguments: BatteryCaptureMode.allCases)
    func mainsChangesNothing(mode: BatteryCaptureMode) {
        let decision = PowerPolicy.decide(power: .mains, mode: mode, baseIntervalSeconds: 60)
        #expect(decision.captureIntervalSeconds == 60)
        #expect(decision.describeAllowed)
        #expect(!PowerPolicy.isEasedOff(power: .mains, mode: mode))
    }

    @Test("`slow` stretches the interval and keeps describing")
    func slowStretchesTheInterval() {
        let decision = PowerPolicy.decide(
            power: PowerState(onBattery: true), mode: .slow, baseIntervalSeconds: 60
        )
        #expect(decision.captureIntervalSeconds == 300)
        #expect(decision.describeAllowed)
    }

    @Test("`describe-later` stretches the interval and holds the queue")
    func describeLaterHoldsTheQueue() {
        let decision = PowerPolicy.decide(
            power: PowerState(onBattery: true), mode: .describeLater, baseIntervalSeconds: 60
        )
        #expect(decision.captureIntervalSeconds == 300)
        #expect(!decision.describeAllowed)
    }

    @Test("`normal` ignores the battery entirely")
    func normalIgnoresTheBattery() {
        let decision = PowerPolicy.decide(
            power: PowerState(onBattery: true, lowPowerMode: true),
            mode: .normal,
            baseIntervalSeconds: 60
        )
        #expect(decision.captureIntervalSeconds == 60)
        #expect(decision.describeAllowed)
        #expect(!PowerPolicy.isEasedOff(power: PowerState(onBattery: true), mode: .normal))
    }

    @Test("Low Power Mode counts even on the charger")
    func lowPowerModeOnMains() {
        let power = PowerState(onBattery: false, lowPowerMode: true)
        #expect(power.wantsRestraint)
        #expect(PowerPolicy.decide(power: power, mode: .slow, baseIntervalSeconds: 60)
            .captureIntervalSeconds == 300)
    }

    @Test("The meeting cadence is stretched from whatever it already was")
    func stretchesTheMeetingCadence() {
        // The scheduler hands in the meeting interval while a meeting is on; the policy multiplies
        // whatever it is given rather than knowing about meetings.
        #expect(PowerPolicy.decide(
            power: PowerState(onBattery: true), mode: .slow, baseIntervalSeconds: 300
        ).captureIntervalSeconds == 1500)
    }

    @Test("CAPTURE_ON_BATTERY round-trips through the config registry")
    func configRoundTrip() throws {
        #expect(Config.defaults().captureOnBattery == .slow)
        let loaded = try Config.load(layers: [["CAPTURE_ON_BATTERY": "describe-later"]])
        #expect(loaded.captureOnBattery == .describeLater)
    }
}
