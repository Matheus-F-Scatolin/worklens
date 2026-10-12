import Foundation
import Testing
@testable import WorklensCore

/// #340: a Granola note with no calendar link merges into the event it overlaps substantially,
/// the rule `main` used before #318; a linked note keeps #318's rule, and a link always wins.
@Suite("ContextBlocks.deduplicate, unlinked notes")
struct ContextBlocksDedupeTests {
    private let start = Date(timeIntervalSince1970: 1_788_739_200) // 2026-09-07 00:00 UTC

    private func at(_ hour: Int, _ minute: Int) -> Date {
        start.addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
    }

    private func meeting(
        _ externalId: String, source: ContextSource = .calendar,
        from: Date, to: Date, linkedTo calendarEventId: String? = nil
    ) -> ContextEvent {
        ContextEvent(
            source: source, externalId: externalId, startAt: from, endAt: to,
            isMeeting: true,
            rawJson: calendarEventId.map { #"{"calendar_event":{"calendar_event_id":"\#($0)"}}"# }
        )
    }

    @Test("an unlinked note that overlaps an event substantially is one meeting: the Granola copy")
    func unlinkedSubstantialOverlapMerges() {
        let kept = ContextBlocks.deduplicate([
            meeting("cal-1", from: at(10, 0), to: at(11, 0)),
            meeting("gr-1", source: .granola, from: at(10, 5), to: at(10, 50)),
        ])
        #expect(kept.map(\.externalId) == ["gr-1"])
    }

    @Test("an unlinked note that overlaps an event only slightly keeps both")
    func unlinkedSlightOverlapKeepsBoth() {
        let kept = ContextBlocks.deduplicate([
            meeting("cal-1", from: at(10, 0), to: at(11, 0)),
            // 15 of the shorter event's 60 minutes overlap: a quarter, below the half the rule needs.
            meeting("gr-1", source: .granola, from: at(10, 45), to: at(11, 45)),
        ])
        #expect(kept.map(\.externalId) == ["cal-1", "gr-1"])
    }

    @Test("an unlinked note that overlaps exactly half of an event keeps both")
    func unlinkedExactlyHalfKeepsBoth() {
        let kept = ContextBlocks.deduplicate([
            meeting("cal-1", from: at(10, 0), to: at(11, 0)),
            // 30 of 60 minutes: the rule needs more than half.
            meeting("gr-1", source: .granola, from: at(10, 30), to: at(11, 30)),
        ])
        #expect(kept.map(\.externalId) == ["cal-1", "gr-1"])
    }

    @Test("an unlinked note over a calendar double booking drops both invites")
    func unlinkedNoteOverDoubleBookingDropsBoth() {
        let kept = ContextBlocks.deduplicate([
            meeting("cal-a", from: at(10, 0), to: at(11, 0)),
            meeting("cal-b", from: at(10, 0), to: at(11, 0)),
            meeting("gr-1", source: .granola, from: at(10, 2), to: at(10, 58)),
        ])
        #expect(kept.map(\.externalId) == ["gr-1"])
    }

    @Test("a linked note drops the event it names and keeps the one it also overlaps")
    func linkedNoteKeepsDoubleBooking() {
        let kept = ContextBlocks.deduplicate([
            meeting("cal-a", from: at(10, 0), to: at(11, 0)),
            meeting("cal-b", from: at(10, 0), to: at(11, 0)),
            meeting("gr-1", source: .granola, from: at(10, 2), to: at(10, 58), linkedTo: "cal-b"),
        ])
        #expect(Set(kept.map(\.externalId)) == ["cal-a", "gr-1"])
    }

    @Test("an unlinked note never drops an event a linked note names")
    func linkWinsOverGuess() {
        let kept = ContextBlocks.deduplicate([
            meeting("cal-1", from: at(10, 0), to: at(11, 0)),
            // The linked note names cal-1 but sits elsewhere in the day, so it does not claim it.
            meeting("gr-linked", source: .granola, from: at(14, 0), to: at(14, 30), linkedTo: "cal-1"),
            meeting("gr-free", source: .granola, from: at(10, 0), to: at(11, 0)),
        ])
        #expect(Set(kept.map(\.externalId)) == ["cal-1", "gr-free", "gr-linked"])
    }

    @Test("two unlinked notes at the same time both stay")
    func twoUnlinkedNotesStay() {
        let kept = ContextBlocks.deduplicate([
            meeting("gr-1", source: .granola, from: at(10, 0), to: at(11, 0)),
            meeting("gr-2", source: .granola, from: at(10, 0), to: at(11, 0)),
        ])
        #expect(Set(kept.map(\.externalId)) == ["gr-1", "gr-2"])
    }

    @Test("an unlinked note on a call a linked note names and overlaps is a second copy: it goes")
    func unlinkedNoteYieldsToLinkedCopy() {
        let kept = ContextBlocks.deduplicate([
            meeting("cal-1", from: at(10, 0), to: at(11, 0)),
            meeting("gr-linked", source: .granola, from: at(10, 0), to: at(10, 45), linkedTo: "cal-1"),
            meeting("gr-free", source: .granola, from: at(10, 15), to: at(10, 45)),
        ])
        #expect(kept.map(\.externalId) == ["gr-linked"])
    }
}
