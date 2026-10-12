import Foundation

/// Which Mac this is, and whether the data directory has seen a different one.
///
/// Two Macs pointed at one folder is the failure `DataDirLocation` exists to prevent, but a
/// folder that has been copied, restored from a backup or shared over a network can arrive
/// already holding another machine's history. The name recorded on first run is what catches
/// that: it is one row in `app_state`, compared once per launch.
///
/// The name is never sent anywhere. It goes into `app_state`, on your disk, and nowhere else.
public enum MachineName {
    /// `app_state` key holding the machine that first wrote into this data directory.
    public static let stateKey = "machine_name"

    /// What this Mac calls itself — "Matheus's MacBook Pro". Falls back to the host name, which
    /// is never empty, so this always has something to record.
    public static var current: String {
        if let localized = Host.current().localizedName, !localized.isEmpty { return localized }
        return ProcessInfo.processInfo.hostName
    }

    /// What a launch found in `app_state`.
    public enum Match: Sendable, Equatable {
        /// Nothing was recorded: a new data directory, now stamped with `name`.
        case firstRun(name: String)
        case same(name: String)
        /// The folder was last written by a different Mac.
        case different(recorded: String, current: String)

        public var message: String? {
            guard case let .different(recorded, current) = self else { return nil }
            return "This data directory was last written by \"\(recorded)\" and this Mac is "
                + "\"\(current)\". Two Macs cannot share one history: run one install per Mac, each "
                + "with its own DATA_DIR."
        }
    }

    /// Reads the recorded name, writing it on first run. Never throws: a data directory that
    /// cannot be written will say so far more clearly a moment later.
    @discardableResult
    public static func record(in state: AppStateStore, current: String = MachineName.current) -> Match {
        let recorded = (try? state.get(stateKey)) ?? nil
        guard let recorded, !recorded.isEmpty else {
            try? state.set(stateKey, current)
            return .firstRun(name: current)
        }
        guard recorded != current else { return .same(name: recorded) }
        // Restamped rather than kept: renaming your Mac is a real thing people do, and a row
        // that can never clear teaches you to ignore it. The notice log keeps the evidence, and
        // two Macs taking turns on one folder flip the row back on at every launch — which is
        // exactly the signal worth having.
        try? state.set(stateKey, current)
        return .different(recorded: recorded, current: current)
    }
}
