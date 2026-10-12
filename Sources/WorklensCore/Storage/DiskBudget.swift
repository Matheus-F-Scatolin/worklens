import Foundation

/// One day folder under `DATA_DIR/screenshots`, and what it weighs.
public struct ScreenshotDay: Sendable, Equatable {
    /// `YYYY-MM-DD`, the folder's name.
    public var day: String
    public var bytes: Int64
    public var files: Int

    public init(day: String, bytes: Int64, files: Int = 0) {
        self.day = day
        self.bytes = bytes
        self.files = files
    }
}

/// What a sweep did.
public struct DiskSweep: Sendable, Equatable {
    public var bytesBefore: Int64
    public var bytesAfter: Int64
    /// The day folders emptied, oldest first.
    public var daysDeleted: [String]
    public var filesDeleted: Int
    /// Rows whose `image_path` was set to NULL — the descriptions stay.
    public var rowsCleared: Int

    public init(
        bytesBefore: Int64 = 0,
        bytesAfter: Int64 = 0,
        daysDeleted: [String] = [],
        filesDeleted: Int = 0,
        rowsCleared: Int = 0
    ) {
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.daysDeleted = daysDeleted
        self.filesDeleted = filesDeleted
        self.rowsCleared = rowsCleared
    }

    public var freedBytes: Int64 { max(0, bytesBefore - bytesAfter) }
    public var didAnything: Bool { !daysDeleted.isEmpty }
}

/// Keeps `DATA_DIR/screenshots` under `SCREENSHOT_DISK_BUDGET_GB`.
///
/// The rule is coarse on purpose: **whole day folders, oldest first, and never today or
/// yesterday**. Deleting the oldest individual files would keep the number closer to the budget,
/// and would also leave a day half-imaged — the worst state for evidence, which is the reason
/// screenshots are kept at all. A day is the unit a person thinks in.
///
/// What is deleted is only ever pixels. The `captures` rows stay, their `descriptions` stay, and
/// `image_path` becomes NULL — so the timeline and every report over that day are unchanged. A
/// swept day loses the ability to be re-described, nothing else.
public struct DiskBudget: Sendable {
    /// GiB, matching how `SCREENSHOT_DISK_BUDGET_GB` reads.
    public static let bytesPerGiB: Int64 = 1024 * 1024 * 1024
    /// Today and yesterday are never swept, whatever the budget says: they are the days a report
    /// has not been written for yet.
    public static let protectedDays = 2

    private let config: Config
    private let db: Database
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date

    public init(
        config: Config,
        db: Database,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.db = db
        self.timeZone = timeZone
        self.now = now
    }

    public var budgetBytes: Int64 {
        Int64(config.screenshotDiskBudgetGB * Double(DiskBudget.bytesPerGiB))
    }

    // MARK: Measuring

    /// Every day folder with its size, oldest day first. One directory walk.
    public func measure() -> [ScreenshotDay] {
        let root = config.screenshotsDir
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return [] }

        var days: [ScreenshotDay] = []
        for name in names.sorted() {
            // Only folders that are a day: anything else under `screenshots` is not ours to
            // delete, and a name that is not a date has no place in an oldest-first order.
            guard DayBoundaries.range(day: name, timeZone: timeZone) != nil else { continue }
            let folder = root.appendingPathComponent(name)
            var bytes: Int64 = 0
            var files = 0
            for file in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let attributes = try? manager.attributesOfItem(
                    atPath: folder.appendingPathComponent(file).path
                )
                bytes += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                files += 1
            }
            days.append(ScreenshotDay(day: name, bytes: bytes, files: files))
        }
        return days
    }

    public func totalBytes() -> Int64 { measure().reduce(0) { $0 + $1.bytes } }

    // MARK: The decision (pure)

    /// Which day folders to empty, oldest first, to bring `days` under `budgetBytes`.
    ///
    /// Pure over `[ScreenshotDay]`, which is what makes this testable without a filesystem: the
    /// only interesting behaviour is the stopping rule and the two protected days.
    ///
    /// - Parameters:
    ///   - days: every day folder with its size, any order.
    ///   - budgetBytes: `SCREENSHOT_DISK_BUDGET_GB` in bytes.
    ///   - protecting: the days that are never swept — today and yesterday.
    public static func daysToSweep(
        days: [ScreenshotDay], budgetBytes: Int64, protecting: Set<String>
    ) -> [String] {
        var total = days.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > budgetBytes else { return [] }

        var swept: [String] = []
        for day in days.sorted(by: { $0.day < $1.day }) {
            guard total > budgetBytes else { break }
            // A protected day is skipped, not stopped at: a huge today must not save every
            // ancient day behind it from being swept.
            guard !protecting.contains(day.day) else { continue }
            guard day.bytes > 0 else { continue }
            swept.append(day.day)
            total -= day.bytes
        }
        return swept
    }

    /// Today and yesterday, in local time.
    public func protectedDays() -> Set<String> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = now()
        return Set((0..<DiskBudget.protectedDays).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
                .map { DayBoundaries.dayString($0, timeZone: timeZone) }
        })
    }

    // MARK: Sweeping

    /// Deletes whole day folders, oldest first, until the total is under budget. Idempotent and
    /// cheap when there is nothing to do: one directory walk and no writes.
    @discardableResult
    public func sweep() throws -> DiskSweep {
        let days = measure()
        let before = days.reduce(Int64(0)) { $0 + $1.bytes }
        let condemned = DiskBudget.daysToSweep(
            days: days, budgetBytes: budgetBytes, protecting: protectedDays()
        )
        guard !condemned.isEmpty else {
            return DiskSweep(bytesBefore: before, bytesAfter: before)
        }

        var filesDeleted = 0
        var rowsCleared = 0
        for day in condemned {
            let folder = config.screenshotsDir.appendingPathComponent(day)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            // Paths first, files second. A crash in between then leaves files with no row
            // pointing at them — litter the next sweep collects. The other order would leave
            // rows pointing at files that are gone, which `DescribeWorker` reads as a frame
            // that can never be described and marks permanently failed.
            rowsCleared += try CaptureStore(db).clearImagePaths(day: day, timeZone: timeZone)
            for file in files {
                if (try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))) != nil {
                    filesDeleted += 1
                }
            }
            try? FileManager.default.removeItem(at: folder)
        }

        let after = totalBytes()
        let sweep = DiskSweep(
            bytesBefore: before, bytesAfter: after,
            daysDeleted: condemned, filesDeleted: filesDeleted, rowsCleared: rowsCleared
        )
        Log.storage.info(
            "screenshot sweep: \(DiskBudget.humanBytes(before)) → \(DiskBudget.humanBytes(after)) "
                + "of \(DiskBudget.humanBytes(budgetBytes)); emptied \(condemned.count) day(s), "
                + "\(filesDeleted) files, cleared \(rowsCleared) image paths"
        )
        return sweep
    }

    // MARK: Display

    /// `6.3 GB`, `840 MB`, `12 KB` — what Settings shows. Binary units, named the way a Mac
    /// names them.
    public static func humanBytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        let gib = Double(bytesPerGiB)
        if value >= gib { return String(format: "%.1f GB", value / gib) }
        if value >= 1024 * 1024 { return String(format: "%.0f MB", value / (1024 * 1024)) }
        if value >= 1024 { return String(format: "%.0f KB", value / 1024) }
        return "\(bytes) bytes"
    }

    /// `6.3 GB of 20 GB budget` — the Settings line, in one place so the CLI can print it too.
    public static func line(used: Int64, budget: Int64) -> String {
        "\(humanBytes(used)) of \(humanBytes(budget)) budget"
    }
}
