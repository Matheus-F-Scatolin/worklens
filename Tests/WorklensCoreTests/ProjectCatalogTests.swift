import Foundation
import Testing
@testable import WorklensCore

/// 2026-09-09's drift, the fixture #90 is written against: four projects under ten spellings.
private let tenSpellings: [(hint: String, frames: Int)] = [
    ("Riverbend Capital Group", 41),
    ("Riverbend Capital", 14),
    ("worklens", 32),
    ("Worklens", 5),
    ("Meridian", 21),
    ("Meridian Recommendation", 5),
    ("Meridian Lab", 4),
    ("KPL trivia night", 13),
    ("KPL", 3),
    ("Trivia Night", 2),
]

private func observations(
    _ labels: [(hint: String, frames: Int)] = tenSpellings
) -> [Int: ProjectNames.Observation] {
    var result: [Int: ProjectNames.Observation] = [:]
    for (hint, frames) in labels {
        for _ in 0..<frames {
            result[result.count] = ProjectNames.Observation(
                hint: hint, appName: "Claude", windowTitle: "Claude"
            )
        }
    }
    return result
}

private func names(_ resolved: [Int: ProjectNames.Project]) -> Set<String> {
    Set(resolved.values.map(\.name))
}

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklens-projects-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Project resolution (#90)")
struct ProjectResolutionTests {
    @Test("the ten spellings collapse to four projects with no canonical list at all")
    func clusteringAlone() {
        let resolved = ProjectNames.resolve(observations())
        #expect(names(resolved) == ["Riverbend Capital Group", "worklens", "Meridian", "KPL trivia night"])
        #expect(Set(resolved.values.map(\.key)).count == 4)
    }

    @Test("the canonical list decides the spelling, however the day spelled it")
    func canonicalNamesWin() {
        let canonical = [
            ProjectEntry(key: "riverbend", name: "Riverbend Capital Group"),
            ProjectEntry(key: "worklens", name: "Worklens"),
            ProjectEntry(key: "meridian", name: "Meridian"),
            ProjectEntry(key: "kpl", name: "KPL trivia night"),
        ]
        let resolved = ProjectNames.resolve(observations(), projects: canonical)
        #expect(Set(resolved.values.map(\.key)) == ["riverbend", "worklens", "meridian", "kpl"])
        // "worklens" outnumbers "Worklens" 32 to 5, and the list still wins.
        #expect(names(resolved).contains("Worklens"))
        #expect(resolved.count == tenSpellings.reduce(0) { $0 + $1.frames })
    }

    @Test("an alias claims a spelling that shares no words with the name")
    func aliasClaimsUnrelatedSpelling() {
        let canonical = [ProjectEntry(key: "riverbend", name: "Riverbend Capital Group", aliases: ["RCG"])]
        let resolved = ProjectNames.resolve(
            observations([("RCG", 3), ("worklens", 2)]), projects: canonical
        )
        #expect(resolved.values.filter { $0.key == "riverbend" }.count == 3)
        #expect(names(resolved) == ["Riverbend Capital Group", "worklens"])
    }

    @Test("a rare hint naming two projects joins the heavier one instead of merging them")
    func compoundHintDoesNotMerge() {
        // 2026-09-09's real shape: two frames of the compound spelling against 59 and 41.
        let resolved = ProjectNames.resolve(observations([
            ("Riverbend Capital Group", 59),
            ("Meridian", 41),
            ("Riverbend Capital Group - Meridian", 2),
        ]))
        let counts = resolved.values.reduce(into: [String: Int]()) { $0[$1.name, default: 0] += 1 }
        #expect(counts == ["Riverbend Capital Group": 61, "Meridian": 41])
    }

    @Test("a compound spelling that is the common one is still the project's name")
    func compoundHintThatIsTheName() {
        // "KPL trivia night" contains two unrelated labels too, and is the name of the thing.
        let resolved = ProjectNames.resolve(observations([
            ("KPL trivia night", 13), ("KPL", 3), ("Trivia Night", 2),
        ]))
        #expect(names(resolved) == ["KPL trivia night"])
    }

    @Test("matching ignores case, accents and repeated spaces")
    func foldedMatching() {
        let entry = ProjectEntry(key: "meridian", name: "Méridian Lab")
        #expect(entry.matches("meridian  lab"))
        #expect(entry.matches("MERIDIAN LAB"))
        #expect(!entry.matches("meridian labs"))
    }
}

@Suite("Project learning (#90)")
struct ProjectLearningTests {
    @Test("a hint clustering with a known project becomes an alias")
    func learnsAnAlias() throws {
        let known = [ProjectEntry(key: "riverbend", name: "Riverbend Capital Group")]
        let learned = try #require(ProjectLearning.learned(
            projects: known,
            byDay: [
                "2026-09-08": [ProjectNames.Observation(hint: "Riverbend Capital Group")],
                "2026-09-09": [ProjectNames.Observation(hint: "Riverbend Capital")],
            ]
        ))
        #expect(learned.count == 1)
        #expect(learned[0].aliases == ["Riverbend Capital"])
        // Day three has nothing left to learn.
        #expect(ProjectLearning.learned(
            projects: learned, byDay: ["2026-09-10": [ProjectNames.Observation(hint: "Riverbend Capital")]]
        ) == nil)
    }

    @Test("an unknown hint creates nothing on day one and a project on day two")
    func twoDaysToBecomeAProject() throws {
        let dayOne = ["2026-09-08": [ProjectNames.Observation(hint: "Meridian")]]
        #expect(ProjectLearning.learned(projects: [], byDay: dayOne) == nil)

        var dayTwo = dayOne
        dayTwo["2026-09-09"] = [
            ProjectNames.Observation(hint: "Meridian"),
            ProjectNames.Observation(hint: "Meridian Lab"),
        ]
        let learned = try #require(ProjectLearning.learned(projects: [], byDay: dayTwo))
        #expect(learned.map(\.key) == ["meridian"])
        #expect(learned[0].name == "Meridian")
        #expect(learned[0].aliases == ["Meridian Lab"])
    }

    @Test("two days of the same day-one hint on one day is still one day")
    func oneDayIsNeverEnough() {
        let byDay = ["2026-09-09": Array(repeating: ProjectNames.Observation(hint: "Meridian"), count: 40)]
        #expect(ProjectLearning.learned(projects: [], byDay: byDay) == nil)
    }
}

@Suite("ProjectCatalog (#90)")
struct ProjectCatalogTests {
    private func store() throws -> (TaxonomyStore, URL) {
        let dir = tempDir()
        return (try TaxonomyStore(dataDir: dir), dir)
    }

    @Test("the seed ships an empty list and an old file without one still decodes")
    func optionalInCodable() throws {
        #expect(Taxonomy.seed.projectList.isEmpty)
        let old = #"{"version": 1, "apps": [], "universal_tasks": []}"#
        let taxonomy = try Taxonomy.decode(Data(old.utf8))
        #expect(taxonomy.projects == nil)
        #expect(taxonomy.projectList.isEmpty)
    }

    @Test("an alias round-trips through save and reload")
    func aliasRoundTrips() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }

        var next = store.current
        next.projects = [ProjectEntry(key: "riverbend", name: "Riverbend Capital Group", aliases: ["Riverbend Capital"])]
        try store.save(next)

        let reloaded = try TaxonomyStore(dataDir: dir)
        #expect(reloaded.projects == next.projects)
        #expect(reloaded.resolveProject(hint: "riverbend capital")?.key == "riverbend")
        #expect(reloaded.resolveProject(hint: "Riverbend Capital Group")?.name == "Riverbend Capital Group")
        #expect(reloaded.resolveProject(hint: "worklens") == nil)
        #expect(reloaded.resolveProject(hint: nil) == nil)
    }

    @Test("two projects claiming one spelling is a validation problem")
    func ambiguousSpellingsAreRefused() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        var next = store.current
        next.projects = [
            ProjectEntry(key: "riverbend", name: "Riverbend Capital Group", aliases: ["RCG"]),
            ProjectEntry(key: "rcg", name: "rcg"),
        ]
        #expect(throws: TaxonomyError.self) { try store.save(next) }
    }

    @Test("rename keeps the old spelling, merge folds one project into another")
    func handEdits() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)
        let db = try Database(dataDir: dir)
        let catalog = ProjectCatalog(db: db, taxonomy: store)

        var seeded = store.current
        seeded.projects = [
            ProjectEntry(key: "riverbend", name: "Riverbend Capital"),
            ProjectEntry(key: "meridian", name: "Meridian", aliases: ["Meridian Lab"]),
        ]
        try store.save(seeded)

        try catalog.rename(key: "riverbend", to: "Riverbend Capital Group")
        #expect(catalog.projects[0].name == "Riverbend Capital Group")
        #expect(catalog.projects[0].aliases == ["Riverbend Capital"])

        try catalog.addAlias("RCG", to: "riverbend")
        #expect(catalog.projects[0].matches("rcg"))
        #expect(throws: ProjectCatalogError.self) { try catalog.addAlias("RCG", to: "riverbend") }

        try catalog.merge(key: "meridian", into: "riverbend")
        #expect(catalog.projects.map(\.key) == ["riverbend"])
        #expect(catalog.projects[0].matches("Meridian Lab"))

        try catalog.removeAlias("RCG", from: "riverbend")
        #expect(!catalog.projects[0].matches("RCG"))

        try catalog.forget(key: "riverbend")
        #expect(catalog.projects.isEmpty)
        #expect(throws: ProjectCatalogError.self) { try catalog.forget(key: "riverbend") }
    }

    @Test("#324: rules are added by any spelling, refused when another project owns them, and removed")
    func rules() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)
        let catalog = ProjectCatalog(db: try Database(dataDir: dir), taxonomy: store)
        var seeded = store.current
        seeded.projects = [
            ProjectEntry(key: "acme", name: "Acme Capital"),
            ProjectEntry(key: "beta", name: "Beta"),
        ]
        try store.save(seeded)

        let added = try catalog.addRule(.domain, "Bob@WWW.Acme.com", to: "acme capital")
        #expect(added.value == "acme.com")
        try catalog.addRule(.repo, "https://github.com/Acme/Widgets", to: "acme")
        try catalog.addRule(.urlPrefix, "https://notion.so/acme/?v=1#top", to: "acme")
        #expect(catalog.projects[0].domains == ["acme.com"])
        #expect(catalog.projects[0].rules == ProjectRules(repos: ["acme/widgets"], urlPrefixes: ["notion.so/acme"]))
        // The same rule again changes nothing; on another project it is refused, naming the owner.
        try catalog.addRule(.domain, "acme.com", to: "acme")
        #expect(catalog.projects[0].domains == ["acme.com"])
        #expect(throws: ProjectCatalogError.ruleTaken("acme.com", "acme")) {
            try catalog.addRule(.domain, "www.acme.com", to: "beta")
        }
        #expect(throws: ProjectCatalogError.ruleTaken("acme/widgets", "acme")) {
            try catalog.addRule(.repo, "acme/widgets", to: "beta")
        }
        #expect(throws: ProjectCatalogError.unknownProject("gamma")) {
            try catalog.addRule(.domain, "gamma.com", to: "gamma")
        }
        #expect(throws: ProjectCatalogError.invalidRule(.repo, "widgets")) {
            try catalog.addRule(.repo, "widgets", to: "acme")
        }

        try catalog.removeRule(.urlPrefix, "notion.so/acme/")
        #expect(catalog.projects[0].rules == ProjectRules(repos: ["acme/widgets"]))
        #expect(throws: ProjectCatalogError.unknownRule(.urlPrefix, "notion.so/acme")) {
            try catalog.removeRule(.urlPrefix, "notion.so/acme")
        }
    }

    @Test("#324: merge carries rules and assignments; forget refuses while an assignment points at the key")
    func mergeCarriesRulesAndAssignments() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)
        let db = try Database(dataDir: dir)
        let catalog = ProjectCatalog(db: db, taxonomy: store)
        var seeded = store.current
        seeded.projects = [
            ProjectEntry(key: "acme", name: "Acme", rules: ProjectRules(repos: ["acme/api"])),
            ProjectEntry(
                key: "acme labs", name: "Acme Labs", domains: ["acmelabs.com"],
                rules: ProjectRules(repos: ["acme/labs"], urlPrefixes: ["notion.so/labs"])
            ),
        ]
        try store.save(seeded)
        let assignments = ProjectAssignmentStore(db)
        let row = try assignments.insert(
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 600), projectKey: "acme labs"
        )

        #expect(throws: ProjectCatalogError.assignmentsPointAt("acme labs", 1)) {
            try catalog.forget(key: "acme labs")
        }
        try catalog.merge(key: "acme labs", into: "acme")
        #expect(catalog.projects.map(\.key) == ["acme"])
        #expect(catalog.projects[0].domains == ["acmelabs.com"])
        #expect(catalog.projects[0].rules == ProjectRules(repos: ["acme/api", "acme/labs"], urlPrefixes: ["notion.so/labs"]))
        #expect(try assignments.all().map(\.projectKey) == ["acme"])

        #expect(throws: ProjectCatalogError.assignmentsPointAt("acme", 1)) { try catalog.forget(key: "acme") }
        try assignments.delete(id: row.id)
        try catalog.forget(key: "acme")
        #expect(catalog.projects.isEmpty)
    }

    @Test("a rename shows up in the next resolution")
    func renameChangesResolution() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)
        let catalog = ProjectCatalog(db: try Database(dataDir: dir), taxonomy: store)

        var seeded = store.current
        seeded.projects = [ProjectEntry(key: "worklens", name: "worklens")]
        try store.save(seeded)
        try catalog.rename(key: "worklens", to: "Worklens")

        let resolved = ProjectNames.resolve(
            observations([("worklens", 4)]), projects: store.projects
        )
        #expect(names(resolved) == ["Worklens"])
    }

    @Test("housekeeping learns once per local day, and again the next day")
    func learnsOncePerDay() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let utc = TimeZone(identifier: "UTC")!
        let db = try Database(dataDir: dir)
        let catalog = ProjectCatalog(db: db, taxonomy: try TaxonomyStore(dataDir: dir), timeZone: utc)
        let morning = DayBoundaries.range(day: "2026-10-05", timeZone: utc)!.start
            .addingTimeInterval(9 * 3600)

        #expect(try catalog.learnIfDue(now: morning) != nil)
        #expect(try AppStateStore(db).get(ProjectCatalog.lastLearnedKey) == "2026-10-05")
        // A later pass the same day has already run.
        #expect(try catalog.learnIfDue(now: morning.addingTimeInterval(8 * 3600)) == nil)
        // The next local day runs again.
        #expect(try catalog.learnIfDue(now: morning.addingTimeInterval(24 * 3600)) != nil)
        #expect(try AppStateStore(db).get(ProjectCatalog.lastLearnedKey) == "2026-10-06")
    }
}

// MARK: - Kinds and keys (#315)

@Suite("Project kinds and keys (#315)")
struct ProjectKindTests {
    @Test("an entry without a kind decodes, and a kind round-trips through the file")
    func kindIsOptional() throws {
        let old = #"{"version": 1, "apps": [], "universal_tasks": [], "projects": [{"key": "acme", "name": "Acme"}]}"#
        let taxonomy = try Taxonomy.decode(Data(old.utf8))
        #expect(taxonomy.projectList.first?.kind == nil)

        var marked = taxonomy
        marked.projects = [ProjectEntry(key: "acme", name: "Acme", kind: .company)]
        let data = try Taxonomy.encoder().encode(marked)
        #expect(String(decoding: data, as: UTF8.self).contains(#""kind" : "company""#))
        #expect(try Taxonomy.decode(data).projectList.first?.kind == .company)
    }

    @Test("a kind survives every catalog edit, and two house entries fail validation")
    func kindSurvivesEdits() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)
        let db = try Database(dataDir: dir)
        let catalog = ProjectCatalog(db: db, taxonomy: store)

        var seeded = store.current
        seeded.projects = [
            ProjectEntry(key: "firm", name: "Firm"),
            ProjectEntry(key: "acme", name: "Acme"),
            ProjectEntry(key: "acme labs", name: "Acme Labs"),
        ]
        try store.save(seeded)

        try catalog.setKind(.house, for: "firm")
        try catalog.setKind(.company, for: "acme")
        try catalog.rename(key: "acme", to: "Acme Corp")
        try catalog.addAlias("Acme Inc", to: "acme")
        try catalog.removeAlias("Acme Inc", from: "acme")
        try catalog.merge(key: "acme labs", into: "acme")
        try catalog.addAlias("The Firm", to: "firm")
        #expect(catalog.projects.map(\.kind) == [.house, .company])

        // Learning appends to an entry in place, so it keeps the kind too.
        let learned = try #require(ProjectLearning.learned(
            projects: catalog.projects,
            byDay: [
                "2026-10-01": [ProjectNames.Observation(hint: "Acme Corp board deck")],
                "2026-10-02": [ProjectNames.Observation(hint: "Acme Corp board deck")],
            ]
        ))
        #expect(learned.first { $0.key == "acme" }?.kind == .company)

        // A second house is refused by the catalog and by validation.
        #expect(throws: ProjectCatalogError.houseTaken("firm")) { try catalog.setKind(.house, for: "acme") }
        var twoHouses = store.current
        twoHouses.projects?[1].kind = .house
        #expect(throws: TaxonomyError.self) { try store.save(twoHouses) }
        #expect(twoHouses.validationProblems().contains { $0.contains("more than one house") })

        // `none` clears the mark.
        try catalog.setKind(nil, for: "firm")
        #expect(catalog.projects[0].kind == nil)
        #expect(throws: ProjectCatalogError.unknownProject("nope")) { try catalog.setKind(.side, for: "nope") }
    }

    @Test("merge carries the source's kind to an unmarked target, and never drops the house")
    func mergeCarriesKind() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaxonomyStore(dataDir: dir)
        let db = try Database(dataDir: dir)
        let catalog = ProjectCatalog(db: db, taxonomy: store)
        var seeded = store.current
        seeded.projects = [
            ProjectEntry(key: "firm", name: "Firm", kind: .house),
            ProjectEntry(key: "the firm", name: "The Firm"),
            ProjectEntry(key: "acme", name: "Acme", kind: .company),
        ]
        try store.save(seeded)

        #expect(throws: ProjectCatalogError.mergeWouldDropHouse("firm", "acme")) {
            try catalog.merge(key: "firm", into: "acme")
        }
        try catalog.merge(key: "firm", into: "the firm")
        #expect(catalog.projects.map(\.key) == ["the firm", "acme"])
        #expect(catalog.projects[0].kind == .house)
    }

    @Test("learning skips the hints of frames that already resolved by key")
    func learningSkipsKeyedFrames() {
        let projects = [ProjectEntry(key: "acme", name: "Acme Corp", kind: .company)]
        let codename = ProjectNames.Observation(hint: "Project Rocket", projectKey: "acme")
        #expect(ProjectLearning.learned(
            projects: projects, byDay: ["2026-10-01": [codename], "2026-10-02": [codename]]
        ) == nil)
    }

    private let catalog = [
        ProjectEntry(key: "firm", name: "Firm", kind: .house),
        ProjectEntry(key: "acme", name: "Acme Corp", aliases: ["acme labs"], kind: .company),
    ]

    @Test("a d5 key resolves even when the hint is null or only echoes the app")
    func keyOutranksHint() {
        let resolved = ProjectNames.resolve(
            [
                1: ProjectNames.Observation(hint: nil, projectKey: "acme"),
                2: ProjectNames.Observation(hint: "Slack", appName: "Slack", projectKey: "acme"),
                3: ProjectNames.Observation(hint: "Firm", projectKey: "acme"),
            ],
            projects: catalog
        )
        #expect(resolved[1] == ProjectNames.Project(key: "acme", name: "Acme Corp"))
        #expect(resolved[2]?.key == "acme")
        #expect(resolved[3]?.key == "acme")
    }

    @Test("an unknown key is dropped, and a merged key resolves to the target")
    func unknownAndMergedKeys() {
        let resolved = ProjectNames.resolve(
            [
                1: ProjectNames.Observation(hint: "Firm", projectKey: "gone"),
                2: ProjectNames.Observation(hint: nil, projectKey: "gone"),
                3: ProjectNames.Observation(hint: nil, projectKey: "acme labs"),
            ],
            projects: catalog
        )
        #expect(resolved[1]?.key == "firm")
        #expect(resolved[2] == nil)
        #expect(resolved[3]?.key == "acme")
        var taxonomy = Taxonomy.seed
        taxonomy.projects = catalog
        #expect(taxonomy.project(forKey: "acme labs")?.key == "acme")
        #expect(taxonomy.project(forKey: "gone") == nil)
    }

    @Test("a d4 row reads the same: no key, the hint decides")
    func d4RowUnchanged() {
        let d4 = TimelineFrame.details(json: #"{"document":"Deck","people":["Ana"],"project_hint":"Acme Corp"}"#)
        #expect(d4 == TimelineFrame.Details(document: "Deck", projectHint: "Acme Corp", projectKey: nil))
        let observation = ProjectNames.Observation(hint: d4.projectHint, projectKey: d4.projectKey)
        #expect(ProjectNames.resolve([1: observation], projects: catalog)
            == ProjectNames.resolve([1: ProjectNames.Observation(hint: "Acme Corp")], projects: catalog))
    }
}
