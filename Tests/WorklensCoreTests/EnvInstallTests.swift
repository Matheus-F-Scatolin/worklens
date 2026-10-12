import Foundation
import Testing

@testable import WorklensCore

/// `worklens install-env` merges rather than copies (#129), and still pins `DATA_DIR` (#34).
@Suite("install-env merge")
struct EnvInstallTests {
    private let checkout = URL(fileURLWithPath: "/Users/dev/worklens", isDirectory: true)
    private let appSupport = URL(
        fileURLWithPath: "/Users/dev/Library/Application Support/Worklens", isDirectory: true
    )

    private func plan(
        source: String,
        destination: String?,
        dataDir: String? = nil,
        pin: Bool = true,
        force: Bool = false
    ) -> EnvInstall.Plan {
        let rule: EnvInstall.Pin
        if let dataDir {
            rule = .explicit(dataDir, checkout: checkout)
        } else if pin {
            rule = .checkout(checkout)
        } else {
            rule = .off(checkout: checkout)
        }
        return EnvInstall.plan(
            source: source,
            destination: destination,
            destinationDirectory: appSupport,
            pin: rule,
            force: force
        )
    }

    @Test("no destination file: the source is installed whole, DATA_DIR pinned")
    func firstInstall() {
        let result = plan(source: "GEMINI_API_KEY=g\nDATA_DIR=./data\n", destination: nil)

        #expect(result.isNewFile)
        #expect(result.conflicts.isEmpty)
        #expect(result.added == ["GEMINI_API_KEY", "DATA_DIR"])
        #expect(result.dataDir == "/Users/dev/worklens/data")
        #expect(DotEnv.parse(result.text)["DATA_DIR"] == "/Users/dev/worklens/data")
    }

    @Test("a key only the installed file sets is kept, and its comments survive")
    func keepsDestinationOnlyKeys() {
        let result = plan(
            source: "GEMINI_API_KEY=g\n",
            destination: "# my own notes\nGRANOLA_API_KEY=installed\nDATA_DIR=/elsewhere\n"
        )

        let values = DotEnv.parse(result.text)
        #expect(values["GRANOLA_API_KEY"] == "installed")
        #expect(values["GEMINI_API_KEY"] == "g")
        #expect(result.text.contains("# my own notes"))
        #expect(result.added == ["GEMINI_API_KEY"])
        #expect(result.text.contains("# Added by `worklens install-env` from /Users/dev/worklens."))
    }

    @Test("a disagreement is listed and the installed value stays")
    func conflictKeepsDestination() {
        let result = plan(
            source: "CAPTURE_INTERVAL_SECONDS=30\nDATA_DIR=./data\n",
            destination: "CAPTURE_INTERVAL_SECONDS=90\nDATA_DIR=/other/data\n"
        )

        #expect(result.taken.isEmpty)
        #expect(result.added.isEmpty)
        #expect(!result.changesFile)
        #expect(DotEnv.parse(result.text)["CAPTURE_INTERVAL_SECONDS"] == "90")
        #expect(DotEnv.parse(result.text)["DATA_DIR"] == "/other/data")
        #expect(result.dataDir == "/other/data")
        #expect(result.previousDataDir == nil)

        let conflicts = result.conflicts.sorted { $0.key < $1.key }
        #expect(conflicts.map(\.key) == ["CAPTURE_INTERVAL_SECONDS", "DATA_DIR"])
        #expect(conflicts[0].source == "30")
        #expect(conflicts[0].destination == "90")
        #expect(conflicts[1].source == "/Users/dev/worklens/data")
        #expect(result.kept.count == 2)
    }

    @Test("--force takes this checkout's value, in place, keeping `export` and indentation")
    func forceTakesSource() {
        let result = plan(
            source: "CAPTURE_INTERVAL_SECONDS=30\n",
            destination: "export CAPTURE_INTERVAL_SECONDS=90\n",
            force: true
        )

        #expect(result.taken == ["CAPTURE_INTERVAL_SECONDS"])
        #expect(result.kept.isEmpty)
        #expect(result.changesFile)
        #expect(result.text.contains("export CAPTURE_INTERVAL_SECONDS=30"))
    }

    @Test("a secret's values are masked in the diff, never printed whole")
    func masksSecrets() throws {
        let result = plan(
            source: "GRANOLA_API_KEY=grn_abc-source-secret\n",
            destination: "GRANOLA_API_KEY=grn_abc-installed-secret\n"
        )

        let conflict = try #require(result.conflicts.first)
        #expect(conflict.source == "grn_abc****")
        #expect(conflict.destination == "grn_abc****")
        #expect(!conflict.source.contains("source-secret"))
        #expect(!conflict.destination.contains("installed-secret"))
        // The installed key itself is untouched: a conflict is reported, never resolved.
        #expect(DotEnv.parse(result.text)["GRANOLA_API_KEY"] == "grn_abc-installed-secret")
        #expect(result.taken.isEmpty)
    }

    @Test("a file that sets no DATA_DIR gets one pinned to the checkout")
    func appendsAPin() {
        let result = plan(source: "GEMINI_API_KEY=g\n", destination: nil)

        #expect(result.dataDir == "/Users/dev/worklens/data")
        #expect(result.text.contains("DATA_DIR=/Users/dev/worklens/data"))
        #expect(result.text.contains("# Pinned by `worklens install-env`"))
    }

    @Test("--no-pin leaves DATA_DIR exactly as written and reports where it will point")
    func noPin() {
        let result = plan(source: "DATA_DIR=./data\n", destination: nil, pin: false)

        #expect(DotEnv.parse(result.text)["DATA_DIR"] == "./data")
        // Read from Application Support, `./data` means Application Support's own data folder.
        #expect(result.dataDir == "/Users/dev/Library/Application Support/Worklens/data")
    }

    @Test("--data-dir is an instruction, so it wins DATA_DIR without --force")
    func explicitDataDirWins() {
        let result = plan(
            source: "DATA_DIR=./data\nGEMINI_API_KEY=g\n",
            destination: "DATA_DIR=/old/data\nGEMINI_API_KEY=g\n",
            dataDir: "/new/data"
        )

        #expect(result.taken == ["DATA_DIR"])
        #expect(result.dataDir == "/new/data")
        #expect(result.previousDataDir == "/old/data")
        #expect(DotEnv.parse(result.text)["DATA_DIR"] == "/new/data")
    }

    @Test("an absolute or ~ DATA_DIR in the source is left as the author wrote it")
    func absolutePathsSurvive() {
        let result = plan(source: "DATA_DIR=/pinned/already\n", destination: nil)

        #expect(result.dataDir == "/pinned/already")
        #expect(DotEnv.parse(result.text)["DATA_DIR"] == "/pinned/already")
    }

    @Test("the same values on both sides is neither a conflict nor a write")
    func agreementIsQuiet() {
        let text = "GEMINI_API_KEY=g\nDATA_DIR=/Users/dev/worklens/data\n"
        let result = plan(source: "GEMINI_API_KEY=g\nDATA_DIR=./data\n", destination: text)

        #expect(result.conflicts.isEmpty)
        #expect(result.added.isEmpty)
        #expect(!result.changesFile)
    }

    @Test("an empty value in the checkout is not a value: --force cannot blank an installed key")
    func emptySourceValueNeverOverwrites() {
        // The shape every checkout has once the real keys live only in Application Support
        // (#116): `.env.example`'s blanks on one side, the working credentials on the other.
        let result = plan(
            source: "GEMINI_API_KEY=\nGRANOLA_API_KEY=\nDATA_DIR=./data\n",
            destination: "GEMINI_API_KEY=real\nGRANOLA_API_KEY=alsoreal\nDATA_DIR=/Users/dev/worklens/data\n",
            force: true
        )

        #expect(result.conflicts.isEmpty)
        #expect(result.added.isEmpty)
        #expect(result.taken.isEmpty)
        #expect(!result.changesFile)

        let values = DotEnv.parse(result.text)
        #expect(values["GEMINI_API_KEY"] == "real")
        #expect(values["GRANOLA_API_KEY"] == "alsoreal")
    }

    @Test("an empty value in the checkout is not added to a file that never had the key")
    func emptySourceValueIsNotAdded() {
        let result = plan(
            source: "GEMINI_API_KEY=\nCAPTURE_INTERVAL_SECONDS=30\nDATA_DIR=./data\n",
            destination: "DATA_DIR=/Users/dev/worklens/data\n"
        )

        #expect(result.added == ["CAPTURE_INTERVAL_SECONDS"])
        #expect(!result.text.contains("GEMINI_API_KEY"))
    }

    @Test("a blank installed key is filled from the checkout, in place, under --force")
    func fillsABlankInstalledKey() {
        let result = plan(
            source: "GEMINI_API_KEY=g\n",
            destination: "GEMINI_API_KEY=\n",
            force: true
        )

        #expect(result.conflicts.map(\.key) == ["GEMINI_API_KEY"])
        #expect(result.taken == ["GEMINI_API_KEY"])
        #expect(DotEnv.parse(result.text)["GEMINI_API_KEY"] == "g")
    }

    @Test("the three-column diff names the file each value came from")
    func diffColumns() {
        let lines = EnvInstall.diffLines([
            EnvInstall.Conflict(key: "DATA_DIR", source: "/a", destination: "/b")
        ])

        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("key"))
        #expect(lines[0].contains("this checkout"))
        #expect(lines[0].hasSuffix("installed"))
        #expect(lines[1].hasPrefix("DATA_DIR"))
        #expect(lines[1].contains("/a"))
        #expect(lines[1].hasSuffix("/b"))
    }
}
