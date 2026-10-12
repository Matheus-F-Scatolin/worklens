import Foundation
import os

/// Thin wrapper over `os.Logger`, one category per subsystem area, filtered by `LOG_LEVEL`.
///
/// Every line also goes to `FileLog`, which appends it to `DATA_DIR/logs/worklens-<day>.log`
/// — the unified log ages out, and an app you leave running for months needs a record you can
/// still read next week. `Log.configure(_:)` is what points the file sink at `DATA_DIR`.
///
/// Privacy: never pass screenshot contents, window titles, URLs or API keys at `info` or
/// above. Use `debug` for anything that could contain user content, or `redactForLog` to keep
/// the shape without the content.
public struct Log: Sendable {
    public let category: String
    private let logger: Logger

    public init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: Log.subsystem, category: category)
    }

    public static let subsystem = "dev.worklens"

    public static let capture = Log(category: "capture")
    public static let describe = Log(category: "describe")
    public static let ui = Log(category: "ui")
    public static let net = Log(category: "net")
    public static let storage = Log(category: "storage")
    public static let config = Log(category: "config")

    // MARK: Level

    private static let levelLock = OSAllocatedUnfairLock(initialState: LogLevel.info)

    /// The minimum level that is emitted. Set once at startup from `Config.logLevel`.
    public static var minimumLevel: LogLevel {
        get { levelLock.withLock { $0 } }
        set { levelLock.withLock { $0 = newValue } }
    }

    /// Sets the level and starts the file sink under `DATA_DIR/logs`, pruning what has aged
    /// out. Called once at startup, and again after `reloadConfig()` — `DATA_DIR` may have moved.
    public static func configure(_ config: Config) {
        minimumLevel = config.logLevel
        let pruned = FileLog.shared.start(directory: config.logsDir)
        Log.storage.info(
            "logging to \(config.logsDir.path)/worklens-<day>.log at \(config.logLevel.rawValue)"
                + (pruned > 0 ? "; pruned \(pruned) aged-out file(s)" : "")
        )
    }

    // MARK: Emission

    public func debug(_ message: @autoclosure () -> String) {
        guard Log.minimumLevel <= .debug else { return }
        let text = message()
        logger.debug("\(text, privacy: .private)")
        FileLog.shared.append(level: .debug, category: category, message: text)
    }

    public func info(_ message: @autoclosure () -> String) {
        guard Log.minimumLevel <= .info else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
        FileLog.shared.append(level: .info, category: category, message: text)
    }

    public func warn(_ message: @autoclosure () -> String) {
        guard Log.minimumLevel <= .warn else { return }
        let text = message()
        logger.warning("\(text, privacy: .public)")
        FileLog.shared.append(level: .warn, category: category, message: text)
    }

    public func error(_ message: @autoclosure () -> String) {
        guard Log.minimumLevel <= .error else { return }
        let text = message()
        logger.error("\(text, privacy: .public)")
        FileLog.shared.append(level: .error, category: category, message: text)
    }
}
