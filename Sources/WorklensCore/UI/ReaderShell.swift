import Foundation

/// The reader's rail: the two places the window can show (core cut, 2026-10-05).
///
/// Both are drawn from numbers: Today is one day's waterfall, Weeks is the week's grid. The
/// Settings gear sits under them and is not a place.
public enum ReaderPlace: String, Sendable, Equatable, CaseIterable, Identifiable {
    case today
    case weeks

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: return L10n.string("Today")
        case .weeks: return L10n.string("Weeks")
        }
    }

    /// Thin-line SF Symbols, the rail's only marks.
    public var symbolName: String {
        switch self {
        case .today: return "sun.max"
        case .weeks: return "calendar.day.timeline.left"
        }
    }
}

/// The colour each app is drawn in. A label only: no colour here means good or bad.
///
/// Five apps are fixed because they are the ones the Claude-desktop style was drawn around; every
/// other app that reaches a top three takes a stable colour from the same muted family, picked by
/// a hash of its name so it is the same colour tomorrow.
public enum AppPalette {
    public static let others: UInt32 = 0x8E8B82
    /// Text on an app-coloured block, in both appearances.
    public static let ink: UInt32 = 0x141413

    static let fixed: [String: UInt32] = [
        "claude desktop": 0xD97757, "claude_desktop": 0xD97757,
        "google calendar": 0x039BE5, "gcal": 0x039BE5,
        "gmail": 0x33B679,
        "google meet": 0x7986CB, "gmeet": 0x7986CB,
        "zoom": 0x9E69AF,
    ]

    /// Muted, mid-light, and far enough from the fixed five to tell apart beside them.
    static let family: [UInt32] = [0xC9A45C, 0x6BA7A0, 0xC08497, 0x8FA86A, 0x7E9CC0, 0xB8876A]

    public static func hex(forApp name: String, key appKey: String? = nil) -> UInt32 {
        if let appKey, let fixed = fixed[appKey.lowercased()] { return fixed }
        let key = name.lowercased()
        if let fixed = fixed[key] { return fixed }
        // FNV-1a: `hashValue` is seeded per process, and this has to survive a relaunch.
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return family[Int(hash % UInt32(family.count))]
    }
}

/// The words the new shell adds.
public enum ReaderShellCopy {
    public static let activeTime = L10n.string("Active time")
    public static let longestFocus = L10n.string("Longest focus block")
    public static let contextSwitches = L10n.string("Context switches")
    public static let meetings = L10n.string("Meetings")
    public static let meeting = L10n.string("Meeting")
    public static let others = L10n.string("Others")
    public static let total = L10n.string("Total")
    public static let noActivity = L10n.string("No activity")
    public static let previousDay = L10n.string("Previous day")
    public static let nextDay = L10n.string("Next day")
    public static let previousWeek = L10n.string("Previous week")
    public static let nextWeek = L10n.string("Next week")
    public static let todayNothing = L10n.string("Nothing recorded on this day yet.")
    public static let weekNothing = L10n.string("Nothing recorded in this week yet.")

    /// `Tuesday, 22 September`, in the viewer's own order and language.
    public static func dayTitle(
        _ day: String, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        guard let start = DayBoundaries.range(day: day, timeZone: timeZone)?.start else { return day }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: start)
    }

    /// `42% of your active time`.
    public static func share(_ percent: Int) -> String {
        L10n.format("%lld%% of your active time", percent)
    }

    /// `Open Mon 21`, for VoiceOver on a week's day header.
    public static func openDay(_ label: String) -> String {
        L10n.format("Open %@", label)
    }

    /// `3 more apps`, for the row that stands for the apps the stats did not name one by one.
    public static func moreApps(_ count: Int) -> String {
        L10n.plural(count: count, one: "%lld more app", other: "%lld more apps")
    }
}
