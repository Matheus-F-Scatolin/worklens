import Foundation

/// The other half of `Log`: one line per event in `DATA_DIR/logs/worklens-YYYY-MM-DD.log`.
///
/// `os.Logger` is the right tool while you are watching (`log stream`), and the wrong one a week
/// later — the unified log ages out, and a menu-bar app you leave running for months needs a
/// record you can still read on Tuesday. So both: `Log` keeps emitting to `os.Logger` and hands
/// every line it emits to the sink here.
///
/// Three things make this safe to leave on:
///
/// - **Buffered.** Lines go into an array and are written every `flushInterval`, on quit, and
///   whenever the buffer passes `maxBufferedLines`. A frame a minute must not mean a `write(2)`
///   a minute plus an `fsync`.
/// - **Rotated.** One file per local day, and files older than `retentionDays` are deleted at
///   launch. There is no size cap, because a day of `info` is a few hundred lines.
/// - **Redacted.** The privacy rule from `CLAUDE.md` holds here too, and `redactForLog` is what
///   the call sites use to keep to it: nothing above `.debug` may carry a window title, a URL, a
///   summary or a key. `.debug` lines are only written when `LOG_LEVEL=debug`, which is a
///   deliberate act.
public final class FileLog: @unchecked Sendable {
    /// How often the buffer is written out.
    public static let flushInterval: TimeInterval = 2
    /// Written immediately at this many buffered lines, whatever the timer is doing.
    public static let maxBufferedLines = 200
    /// Files older than this are deleted at launch.
    public static let retentionDays = 14

    public static let shared = FileLog()

    private let lock = NSLock()
    private var buffer: [String] = []
    private var directory: URL?
    private var timer: DispatchSourceTimer?
    /// Which day's file the buffered lines belong to. A day rollover flushes first.
    private var bufferDay: String?
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    /// Whether this instance has installed its `atexit` flush.
    private var atExitInstalled = false

    public init(timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.timeZone = timeZone
        self.now = now
    }

    // MARK: Lifecycle

    /// Points the sink at `DATA_DIR/logs`, prunes what has aged out, and starts the flush timer.
    /// Idempotent, and safe to call again after `reloadConfig()` moves `DATA_DIR`.
    @discardableResult
    public func start(directory url: URL) -> Int {
        flush()
        lock.lock()
        directory = url
        lock.unlock()

        try? FilePermissions.createPrivateDirectory(at: url)
        let pruned = prune(directory: url)

        // A CLI process exits through `exit()` inside ArgumentParser's `main()`, so there is no
        // code path after it to flush from — without this, everything a short-lived command
        // logged in its last two seconds is lost, which is exactly the interesting part.
        lock.lock()
        let needsAtExit = !atExitInstalled
        atExitInstalled = true
        let alreadyRunning = timer != nil
        lock.unlock()
        if needsAtExit {
            atexit { FileLog.shared.flush() }
        }
        if !alreadyRunning {
            let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            source.schedule(
                deadline: .now() + FileLog.flushInterval, repeating: FileLog.flushInterval
            )
            source.setEventHandler { [weak self] in self?.flush() }
            source.resume()
            lock.lock()
            timer = source
            lock.unlock()
        }
        return pruned
    }

    /// Writes what is buffered and stops the timer. Called from the app's shutdown.
    public func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
        flush()
    }

    // MARK: Writing

    /// Appends one line. Cheap and non-blocking: the string is formatted and buffered, nothing
    /// touches the disk here unless the buffer is already full.
    public func append(level: LogLevel, category: String, message: String) {
        // No directory yet means nothing has called `start` — a unit test, or the moments before
        // config loads. Drop the line rather than buffer it forever.
        lock.lock()
        let hasDirectory = directory != nil
        lock.unlock()
        guard hasDirectory else { return }

        let moment = now()
        let day = DayBoundaries.dayString(moment, timeZone: timeZone)
        let line = "\(FileLog.timestamp(moment, timeZone: timeZone)) "
            + "\(level.rawValue.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) "
            + "\(category) \(message)"

        var shouldFlush = false
        lock.lock()
        // A line written after midnight belongs in tomorrow's file, so the buffer is emptied
        // into today's before the day changes under it.
        if let bufferDay, bufferDay != day, !buffer.isEmpty {
            let stale = buffer
            let staleDay = bufferDay
            buffer = []
            let target = directory
            lock.unlock()
            if let target { FileLog.write(stale, to: FileLog.fileURL(day: staleDay, in: target)) }
            lock.lock()
        }
        bufferDay = day
        buffer.append(line)
        shouldFlush = buffer.count >= FileLog.maxBufferedLines
        lock.unlock()

        if shouldFlush { flush() }
    }

    /// Writes everything buffered. Safe to call from anywhere, including a signal-ish context.
    public func flush() {
        lock.lock()
        guard let directory, !buffer.isEmpty, let day = bufferDay else {
            lock.unlock()
            return
        }
        let lines = buffer
        buffer = []
        lock.unlock()
        FileLog.write(lines, to: FileLog.fileURL(day: day, in: directory))
    }

    /// The file today's lines go to. Public so Settings and the README can name it.
    public static func fileURL(day: String, in directory: URL) -> URL {
        directory.appendingPathComponent("worklens-\(day).log")
    }

    private static func write(_ lines: [String], to url: URL) {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FilePermissions.writePrivate(data, to: url)
        }
    }

    // MARK: Rotation

    /// Deletes `worklens-*.log` files whose day is more than `retentionDays` old, and reports how
    /// many went. Pure enough to test: the decision is `logFilesToPrune`.
    @discardableResult
    public func prune(directory url: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let condemned = FileLog.logFilesToPrune(
            names: names, today: DayBoundaries.dayString(now(), timeZone: timeZone),
            retentionDays: FileLog.retentionDays, timeZone: timeZone
        )
        for name in condemned {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(name))
        }
        if !condemned.isEmpty {
            Log.storage.info("deleted \(condemned.count) log file(s) older than \(FileLog.retentionDays) days")
        }
        return condemned.count
    }

    /// Which of `names` have aged out. A file whose name does not parse is left alone: this
    /// deletes files, and a surprising name is not grounds for that.
    public static func logFilesToPrune(
        names: [String], today: String, retentionDays: Int, timeZone: TimeZone = .current
    ) -> [String] {
        guard let todayStart = DayBoundaries.range(day: today, timeZone: timeZone)?.start else {
            return []
        }
        let cutoff = todayStart.addingTimeInterval(-Double(retentionDays) * 86_400)
        return names.compactMap { name in
            guard name.hasPrefix("worklens-"), name.hasSuffix(".log") else { return nil }
            let day = String(name.dropFirst("worklens-".count).dropLast(".log".count))
            guard let start = DayBoundaries.range(day: day, timeZone: timeZone)?.start else { return nil }
            return start < cutoff ? name : nil
        }
        .sorted()
    }

    // MARK: Formatting

    /// ISO 8601 **in local time, with the offset**, so a line's clock agrees with the local day
    /// in the file's own name. A UTC timestamp inside `worklens-2026-09-07.log` reads as an
    /// off-by-one bug every evening west of Greenwich.
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone,
        ]
        return formatter.string(from: date)
    }
}

// MARK: - Redaction

public extension Log {
    /// Makes a string safe to put in a log line above `.debug`: keeps enough to recognise the
    /// shape of the thing, drops enough that the line is not a record of what you were reading.
    ///
    /// A window title, a URL or a summary can hold anything — a client's name, a diagnosis, a
    /// password someone pasted into a search box. So: at most `keeping` characters, and if the
    /// text looks like a URL, only its host survives.
    static func redactForLog(_ text: String?, keeping: Int = 24) -> String {
        guard let text, !text.isEmpty else { return "(none)" }
        if let host = URLComponents(string: text)?.host, !host.isEmpty {
            return "\(host)/…"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > keeping else { return trimmed }
        return "\(trimmed.prefix(keeping))… (\(trimmed.count) chars)"
    }

    /// A secret, as a log line may name it: how it starts and nothing else.
    static func redactSecret(_ secret: String?) -> String { Config.mask(secret) }
}
