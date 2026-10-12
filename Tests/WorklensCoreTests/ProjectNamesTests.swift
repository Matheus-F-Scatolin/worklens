import Foundation
import Testing
@testable import WorklensCore

/// 2026-09-08's own hints, with the counts the day really produced: about seven projects under
/// fifteen labels. Whatever `ProjectNames` does, it has to do this.
private let realDay: [(hint: String, frames: Int)] = [
    ("worklens", 43),
    ("Worklens", 3),
    ("KPL trivia night", 13),
    ("KPL", 3),
    ("Trivia Night", 2),
    ("Pinecrest Machines & Riverbend", 10),
    ("Pinecrest Machines", 3),
    ("DD Solara", 7),
    ("Solara", 5),
    ("Solara Trading", 2),
    ("Riverbend Capital Group", 13),
    ("Youka", 18),
    ("Don't stop til you get enough", 3),
    ("", 32),
]

/// One observation per frame, keyed by index. `Youka` came in on Youka's own window, which is what
/// makes it a tool rather than a project.
private func observations(
    _ labels: [(hint: String, frames: Int)] = realDay
) -> [Int: ProjectNames.Observation] {
    var result: [Int: ProjectNames.Observation] = [:]
    for (hint, frames) in labels {
        for _ in 0..<frames {
            result[result.count] = ProjectNames.Observation(
                hint: hint,
                appName: hint == "Youka" ? "Youka" : "Claude",
                windowTitle: hint == "Youka" ? "Youka — Don't stop til you get enough" : "Claude"
            )
        }
    }
    return result
}

/// The distinct display names the resolver produced, most frames first.
private func ranked(_ resolved: [Int: ProjectNames.Project]) -> [String] {
    var counts: [String: Int] = [:]
    for project in resolved.values { counts[project.name, default: 0] += 1 }
    return counts
        .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        .map(\.key)
}

@Suite("ProjectNames")
struct ProjectNamesTests {
    @Test("the day's fifteen labels collapse to its six real projects")
    func realDayCollapses() {
        let resolved = ProjectNames.resolve(observations())
        #expect(ranked(resolved) == [
            "worklens",                 // 43 + 3, the frequent spelling wins the casing
            "KPL trivia night",          // 13 + 3 + 2
            "DD Solara",              // 7 + 5 + 2, joined through the bare "Solara"
            "Pinecrest Machines & Riverbend",   // 10 + 3, tied with Riverbend Capital Group, sorted first
            "Riverbend Capital Group",        // 13, no words shared with Pinecrest Machines & Riverbend
            "Don't stop til you get enough", // 3
        ])
    }

    @Test("a hint that only repeats the frame's own app or window name is not a project")
    func toolNamesAreDropped() {
        let resolved = ProjectNames.resolve(observations())
        #expect(!resolved.values.map(\.name).contains("Youka"))
        // The eighteen Youka frames and the thirty-two empty ones resolve to nothing at all.
        #expect(resolved.count == realDay.reduce(0) { $0 + $1.frames } - 18 - 32)

        let byTitle = ProjectNames.resolve([
            0: .init(hint: "Solara Trading", appName: "Chrome", windowTitle: "solara trading"),
            1: .init(hint: "Solara Trading", appName: "Chrome", windowTitle: "Inbox"),
        ])
        #expect(byTitle[0] == nil)
        #expect(byTitle[1]?.name == "Solara Trading")
    }

    @Test("a label merges only when its whole words appear in the other")
    func wordBoundaries() {
        // "kpl" is inside "kplx" as characters, not as words, so they stay two projects.
        let resolved = ProjectNames.resolve([
            0: .init(hint: "KPL"), 1: .init(hint: "KPLX Holdings"), 2: .init(hint: "KPL trivia night"),
        ])
        #expect(resolved[1]?.name == "KPLX Holdings")
        #expect(resolved[0] == resolved[2])
        #expect(resolved[0] != resolved[1])
    }

    @Test("whitespace and casing are cleaned up before anything is compared")
    func trimmingAndFolding() {
        let resolved = ProjectNames.resolve([
            0: .init(hint: "  worklens  "), 1: .init(hint: "WORKLENS"), 2: .init(hint: "work\tlens"),
            3: .init(hint: "worklens   the  app"), 4: .init(hint: "   "), 5: .init(hint: nil),
        ])
        // Three spellings of one project, plus the longer label they all merge into.
        #expect(Set([resolved[0], resolved[1], resolved[3]]).count == 1)
        #expect(resolved[2]?.name == "work lens")
        #expect(resolved[4] == nil)
        #expect(resolved[5] == nil)
    }

    @Test("the display name is the most frequent spelling, and ties break alphabetically")
    func displayNameIsTheCommonSpelling() {
        let clear = ProjectNames.resolve(observations([("Acme", 1), ("ACME", 5), ("acme", 2)]))
        #expect(ranked(clear) == ["ACME"])

        let tied = ProjectNames.resolve(observations([("bravo", 2), ("Alpha", 2)]))
        // Two labels, no shared words, so two projects — the tie is inside neither.
        #expect(ranked(tied) == ["Alpha", "bravo"])

        let tiedSpelling = ProjectNames.resolve(observations([("Acme", 2), ("ACME", 2)]))
        #expect(ranked(tiedSpelling) == ["ACME"])
    }

    @Test("the grouping does not depend on the order the hints arrive in")
    func orderIndependent() {
        let forwards = ranked(ProjectNames.resolve(observations()))
        let backwards = ranked(ProjectNames.resolve(observations(realDay.reversed())))
        #expect(forwards == backwards)
    }

    @Test("labels that share no words stay separate, however related they look")
    func noGuessing() {
        let resolved = ProjectNames.resolve([
            0: .init(hint: "Solara"), 1: .init(hint: "Trading DD"),
        ])
        #expect(resolved[0] != resolved[1])
    }

    @Test("the key is the folded label, so two days' spellings merge into one week's project")
    func keyIsStableAcrossSpellings() {
        let monday = ProjectNames.resolve([0: .init(hint: "worklens")])
        let tuesday = ProjectNames.resolve([0: .init(hint: "Worklens")])
        #expect(monday[0]?.key == tuesday[0]?.key)
        #expect(monday[0]?.name == "worklens")
        #expect(tuesday[0]?.name == "Worklens")
    }

    @Test("no hints at all resolves to nothing")
    func empty() {
        #expect(ProjectNames.resolve([Int: ProjectNames.Observation]()).isEmpty)
        #expect(ProjectNames.resolve([0: ProjectNames.Observation(hint: "")]).isEmpty)
    }
}
