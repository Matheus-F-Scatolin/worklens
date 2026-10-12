import Foundation
import Testing

@testable import WorklensCore

/// The payloads behind the `--json` flags added in #158 that are renderable offline. Each one is
/// checked against the text form it sits beside, because the whole point is that the two are two
/// renderings of one set of numbers rather than two sources of them.
@Suite("CLI --json shapes")
struct CLIJSONShapeTests {
    private static let noSettings = URL(fileURLWithPath: "/nonexistent/worklens/settings.json")

    private func scratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-clijson-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: config-dump --json

    @Test("config-dump --json is one row per key, with the same values and masking as the text")
    func configDumpRows() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "GEMINI_API_KEY=abcdefghijklmnop\nCAPTURE_INTERVAL_SECONDS=45\n"
            .write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let (config, provenance) = try Config.loadWithProvenance(
            environment: [:], cwd: dir,
            appSupportEnv: dir.appendingPathComponent("absent.env"), settingsFile: Self.noSettings
        )
        let rows = ConfigDumpText.rows(config: config, provenance: provenance)
        let text = ConfigDumpText.render(config: config, provenance: provenance)

        // Every documented key, once, in the registry's order — the same list the text walks.
        #expect(rows.count == Config.knownKeys.count)
        #expect(Set(rows.map(\.key)) == Set(Config.knownKeys))

        let interval = try #require(rows.first { $0.key == "CAPTURE_INTERVAL_SECONDS" })
        #expect(interval.value == "45")
        #expect(interval.source == ConfigLayer.cwd.label)

        // The masking happens in `Config.dumpLines`, so both forms mask identically — and the
        // key itself must appear in neither.
        let secret = try #require(rows.first { $0.key == "GEMINI_API_KEY" })
        #expect(!secret.value.contains("abcdefghijklmnop"))
        #expect(!text.contains("abcdefghijklmnop"))

        // It is JSON, and it is the `[{key, value, source}]` the docs promise.
        let encoded = try JSONEncoder().encode(rows)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [[String: String]]
        )
        #expect(decoded.allSatisfy { Set($0.keys) == ["key", "value", "source"] })
    }
}
