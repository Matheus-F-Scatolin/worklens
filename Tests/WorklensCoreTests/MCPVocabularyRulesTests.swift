import Foundation
import Testing
@testable import WorklensCore

/// #324: `vocabulary` shows each catalog project's rules; MCP stays read-only, with no new tool.
@Suite("MCP vocabulary rules (#324)")
struct MCPVocabularyRulesTests {
    @Test("vocabulary shows a project's rules, leaves them out when it has none, and never shows the house's domains")
    func vocabularyShowsRules() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-mcp-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        var config = Config.defaults()
        config.dataDir = dataDir
        let db = try Database.inMemory()
        let taxonomy = try TaxonomyStore(dataDir: dataDir)
        var seeded = taxonomy.current
        seeded.projects = [
            ProjectEntry(key: "firm", name: "Firm", kind: .house, domains: ["firm.example"]),
            ProjectEntry(
                key: "acme", name: "Acme Corp", kind: .company, domains: ["acme.com"],
                rules: ProjectRules(repos: ["acme/api"], urlPrefixes: ["notion.so/acme"])
            ),
            ProjectEntry(key: "misc", name: "Misc"),
        ]
        try taxonomy.save(seeded)

        // One frame a little earlier on each project, so each is a term.
        let earlier = Date().addingTimeInterval(-90 * 60)
        for (offset, key) in ["firm", "acme", "misc"].enumerated() {
            let capture = Capture(
                capturedAt: earlier.addingTimeInterval(Double(offset) * 60), appName: "Slack",
                windowTitle: "#general", describeStatus: .described
            )
            try CaptureStore(db).insert(capture)
            try DescriptionStore(db).insert(Description(
                captureId: capture.id, provider: "gemini", model: "gemini-3.5-flash-lite",
                appKey: "slack", taskKey: "reading_messages", summaryMd: "Reads a thread.",
                detailsJson: #"{"project_key":"\#(key)"}"#, createdAt: capture.capturedAt
            ))
        }

        let registry = WorklensMCPTools.registry(config: config, db: db, taxonomy: taxonomy, timeZone: .current)
        let result = try registry.call(name: "vocabulary", arguments: .object([:]))
        #expect(!result.isError)
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
        let projects = try #require(answer["projects"]?.arrayValue)
        func term(_ name: String) throws -> JSONValue { try #require(projects.first { $0["name"]?.stringValue == name }) }

        let acme = try term("Acme Corp")["rules"]
        #expect(acme?["domains"]?.arrayValue?.compactMap(\.stringValue) == ["acme.com"])
        #expect(acme?["repos"]?.arrayValue?.compactMap(\.stringValue) == ["acme/api"])
        #expect(acme?["url_prefixes"]?.arrayValue?.compactMap(\.stringValue) == ["notion.so/acme"])
        #expect(try term("Misc")["rules"] == nil)
        #expect(try term("Firm")["rules"] == nil)
        #expect(!result.text.contains("firm.example"))
    }

    @Test("the tool list is unchanged: no tool writes a rule or an assignment, and vocabulary suggests the dry run")
    func noNewTool() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("worklens-mcp-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        var config = Config.defaults()
        config.dataDir = dataDir
        let registry = WorklensMCPTools.registry(
            config: config, db: try Database.inMemory(), taxonomy: try TaxonomyStore(dataDir: dataDir),
            timeZone: .current
        )
        for tool in registry.tools {
            #expect(tool.annotations == .read)
            #expect(!["rule", "assign", "correct"].contains { tool.name.contains($0) })
        }
        let vocabulary = try #require(registry.tool(named: "vocabulary"))
        #expect(vocabulary.description.contains("worklens projects rule add --domain"))
        #expect(vocabulary.description.contains("--dry-run"))
    }
}
