import Foundation

/// Pages the reader has already built, so stepping back and forth with ‹ › or the arrow keys
/// does not rebuild a page it has just drawn.
///
/// A page is read from the days it covers, so each one is kept beside the index rows of those
/// days and served only while they still match: a day whose frames, descriptions or timeline
/// moved since is built again. Today, and the week holding it, change with every frame without
/// their row always moving, so the reader tick drops them (`dropHoldingToday`); and nothing is
/// served older than `maxAge`, which covers what the index cannot see, like a taxonomy rename.
public struct ReaderDocumentCache: Sendable {
    /// Enough for a run of steps in both directions and their neighbours.
    public static let capacity = 16
    public static let maxAge: TimeInterval = 10 * 60

    private struct Entry: Sendable {
        var document: ReaderDocument
        var rows: [DayIndexEntry?]
        var builtAt: Date
    }

    private var entries: [ReaderSelection: Entry] = [:]
    /// Least recently stored first.
    private var order: [ReaderSelection] = []
    private let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public var count: Int { entries.count }

    /// The page for `selection`, when one was built from the rows `index` still holds.
    public func document(
        for selection: ReaderSelection, index: [String: DayIndexEntry], now: Date = Date()
    ) -> ReaderDocument? {
        guard let entry = entries[selection],
              now.timeIntervalSince(entry.builtAt) < Self.maxAge,
              entry.rows == rows(of: selection, index: index) else { return nil }
        return entry.document
    }

    /// Keeps `document`, stamped with the rows it was built from.
    public mutating func store(
        _ document: ReaderDocument, builtFrom index: [String: DayIndexEntry], at now: Date = Date()
    ) {
        let selection = document.selection
        entries[selection] = Entry(
            document: document, rows: rows(of: selection, index: index), builtAt: now
        )
        order.removeAll { $0 == selection }
        order.append(selection)
        while order.count > Self.capacity {
            entries[order.removeFirst()] = nil
        }
    }

    public mutating func remove(_ selection: ReaderSelection) {
        entries[selection] = nil
        order.removeAll { $0 == selection }
    }

    /// Drops today's page and this week's: the two that move while you read them.
    public mutating func dropHoldingToday(_ today: String) {
        for selection in order
        where ReaderTick.holdsToday(selection, today: today, timeZone: timeZone) {
            remove(selection)
        }
    }

    public mutating func removeAll() {
        entries = [:]
        order = []
    }

    /// The days a page is read from: the day itself, or the week's seven.
    public func days(of selection: ReaderSelection) -> [String] {
        switch selection {
        case let .day(day):
            return [day]
        case let .week(monday):
            let week = ISOWeek.parse(monday, timeZone: timeZone)
                ?? ISOWeek.containing(dayString: monday, timeZone: timeZone)
            return week?.days ?? [monday]
        }
    }

    private func rows(of selection: ReaderSelection, index: [String: DayIndexEntry]) -> [DayIndexEntry?] {
        days(of: selection).map { index[$0] }
    }

    /// The pages one step either side of `selection`, among the loaded days or weeks, newest
    /// first: what ‹ and › would open next, and so what is worth building ahead.
    public static func neighbours(
        of selection: ReaderSelection, days: [String], mondays: [String]
    ) -> [ReaderSelection] {
        switch selection {
        case let .day(day):
            guard let index = days.firstIndex(of: day) else { return [] }
            return [index - 1, index + 1].filter(days.indices.contains).map { .day(days[$0]) }
        case let .week(monday):
            guard let index = mondays.firstIndex(of: monday) else { return [] }
            return [index - 1, index + 1].filter(mondays.indices.contains).map { .week(mondays[$0]) }
        }
    }
}
