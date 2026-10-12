import Foundation

/// What the Mac's power situation is, as far as Worklens cares (#145).
///
/// Two facts, not one. `onBattery` is the charger; `lowPowerMode` is the user having said, in
/// System Settings, that they want less of everything — and a menu-bar app that screenshots the
/// screen every minute is exactly the "everything" they meant, charger or no charger.
public struct PowerState: Equatable, Sendable {
    /// The Mac is running off the battery rather than a power adapter.
    public var onBattery: Bool
    /// `ProcessInfo.processInfo.isLowPowerModeEnabled`.
    public var lowPowerMode: Bool

    public init(onBattery: Bool = false, lowPowerMode: Bool = false) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
    }

    /// A desktop, or a laptop on the charger with Low Power Mode off.
    public static let mains = PowerState()

    /// Whether the policy has anything to consider at all.
    public var wantsRestraint: Bool { onBattery || lowPowerMode }
}

/// What Worklens does on battery — `CAPTURE_ON_BATTERY`.
public enum BatteryCaptureMode: String, Sendable, CaseIterable, Codable {
    /// Battery changes nothing. For a Mac that never leaves a desk.
    case normal
    /// The default: capture at a longer interval, keep describing.
    case slow
    /// `slow`, and hold the describe queue until the charger is back. Frames are still captured
    /// and stay `pending`; the network and the vision model wait for mains.
    case describeLater = "describe-later"
}

/// The battery decision, as a pure function of (power state, setting, configured interval).
///
/// Pure and in `WorklensCore` on purpose (#145): the live power facts arrive through
/// `SystemStateProviding`, which the tests already fake, and everything that follows from them is
/// arithmetic a unit test can check without a battery.
public enum PowerPolicy {
    /// How much longer the interval gets on battery. Five, so the shipped 60 s default becomes
    /// the same 5 minutes the meeting cadence already uses — a number the menu can say in words.
    public static let batteryIntervalMultiplier = 5

    public struct Decision: Equatable, Sendable {
        /// The interval the scheduler should actually sleep for.
        public let captureIntervalSeconds: Int
        /// Whether the describe queue may make calls right now.
        public let describeAllowed: Bool

        public init(captureIntervalSeconds: Int, describeAllowed: Bool) {
            self.captureIntervalSeconds = captureIntervalSeconds
            self.describeAllowed = describeAllowed
        }
    }

    /// `baseIntervalSeconds` is whatever the scheduler would have used anyway — the capture
    /// interval, or the meeting one while a meeting is on.
    public static func decide(
        power: PowerState,
        mode: BatteryCaptureMode,
        baseIntervalSeconds: Int
    ) -> Decision {
        guard PowerPolicy.isEasedOff(power: power, mode: mode) else {
            return Decision(captureIntervalSeconds: baseIntervalSeconds, describeAllowed: true)
        }
        return Decision(
            captureIntervalSeconds: baseIntervalSeconds * PowerPolicy.batteryIntervalMultiplier,
            describeAllowed: mode != .describeLater
        )
    }

    /// Whether the policy is changing anything right now — what the menu asks before saying so.
    public static func isEasedOff(power: PowerState, mode: BatteryCaptureMode) -> Bool {
        power.wantsRestraint && mode != .normal
    }
}
