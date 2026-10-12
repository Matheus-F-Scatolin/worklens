import Foundation

/// Where a frame's JPEG lives on disk: `DATA_DIR/screenshots/YYYY-MM-DD/HHmmss_<id8>.jpg`,
/// in local time so a day's folder matches the day the user experienced.
public enum ScreenshotPaths {
    /// The absolute URL for a frame, creating the day folder if needed.
    public static func url(for date: Date, id: String, dataDir: URL, timeZone: TimeZone = .current) throws -> URL {
        let directory = directory(for: date, dataDir: dataDir, timeZone: timeZone)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename(for: date, id: id, timeZone: timeZone))
    }

    /// The day folder, without touching the filesystem.
    public static func directory(for date: Date, dataDir: URL, timeZone: TimeZone = .current) -> URL {
        dataDir
            .appendingPathComponent("screenshots")
            .appendingPathComponent(DayBoundaries.dayString(date, timeZone: timeZone))
    }

    /// `HHmmss_<first 8 chars of id>.jpg`.
    public static func filename(for date: Date, id: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HHmmss"
        let short = String(id.replacingOccurrences(of: "-", with: "").prefix(8))
        return "\(formatter.string(from: date))_\(short).jpg"
    }

    /// The path stored in `captures.image_path`: relative to `DATA_DIR`, so moving the data
    /// directory does not invalidate the database.
    public static func relativePath(for date: Date, id: String, timeZone: TimeZone = .current) -> String {
        "screenshots/\(DayBoundaries.dayString(date, timeZone: timeZone))/\(filename(for: date, id: id, timeZone: timeZone))"
    }

    /// Deletes the JPEGs `CaptureStore.deleteRange` just orphaned, and says how many really
    /// went. Both deletion paths call this — the time-range purge (`DataEraser`) and the age
    /// policy (`Retention`, #144) — so neither can drift on how a stored relative path is
    /// resolved or on what an already-missing file means (nothing: a described-and-deleted
    /// frame has no file left, and that is not a failure).
    @discardableResult
    public static func unlink(relativePaths: [String], dataDir: URL) -> Int {
        var removed = 0
        for relative in relativePaths {
            let url = dataDir.appendingPathComponent(relative)
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
