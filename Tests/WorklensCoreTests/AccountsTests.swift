import Foundation
import Testing
@testable import WorklensCore

/// Settings → Models & cost → Accounts (#124): the rows, the entry rules, the precedence between
/// the settings store and the two `.env` files, and the ledger row a `Verify` press writes.
///
/// Not one test here opens a socket: the verifier goes through `KeyProbing`, and the probe in
/// this file answers from a dictionary.
@Suite("Accounts (#124)")
struct AccountsTests {
    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worklens-accounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Rows

    @Test("a row masks the key and never carries it")
    func rowMasksTheKey() {
        var config = Config.defaults(cwd: URL(fileURLWithPath: "/tmp"))
        config.geminiAPIKey = "AIzaSyABCDEFGHIJKLMNOP"
        let provenance = ConfigProvenance(sources: ["GEMINI_API_KEY": .appSettings])

        let row = Accounts.row(.gemini, config: config, provenance: provenance)
        #expect(row.isSet)
        #expect(row.masked == "AIzaSyA****")
        #expect(!row.masked.contains("MNOP"))
        #expect(row.status == .ok)
        #expect(row.statusText == "Set")
        // Worklens's own store supplies it: nothing to explain.
        #expect(row.sourceNote == nil)
        #expect(row.isEditable)
        #expect(row.isStored)
    }

    @Test("a key nobody set reads as missing, and says what stops")
    func missingKey() throws {
        let config = Config.defaults(cwd: URL(fileURLWithPath: "/tmp"))
        let rows = Accounts.rows(config: config, provenance: ConfigProvenance())

        #expect(rows.map(\.provider) == [.gemini])
        for row in rows {
            #expect(!row.isSet)
            #expect(row.masked == AccountRow.unsetText)
            // Nothing stored, so there is nothing for "Remove" to remove.
            #expect(!row.isStored)
        }

        // #240: the Gemini key is what Worklens cannot record without, so its absence is a fault.
        let gemini = try #require(rows.first { $0.provider == .gemini })
        #expect(gemini.status == .problem)
        #expect(gemini.statusText == "Missing")
        #expect(gemini.sourceNote?.contains("until this is set") == true)
    }

    /// The row's job when a `.env` supplies the value: say so, rather than letting the user
    /// wonder why the field they are about to type into looks empty.
    @Test("a value from a .env is named, not shadowed in silence")
    func namesTheEnvFile() {
        var config = Config.defaults(cwd: URL(fileURLWithPath: "/tmp"))
        config.geminiAPIKey = "AIzaSecret"

        let fromCwd = Accounts.row(
            .gemini, config: config,
            provenance: ConfigProvenance(sources: ["GEMINI_API_KEY": .cwd])
        )
        #expect(fromCwd.isEditable)
        #expect(!fromCwd.isStored)
        #expect(fromCwd.sourceNote?.contains(".env beside this checkout") == true)

        let fromAppSupport = Accounts.row(
            .gemini, config: config,
            provenance: ConfigProvenance(sources: ["GEMINI_API_KEY": .appSupport])
        )
        #expect(fromAppSupport.sourceNote?.contains("Application Support") == true)
    }

    /// The two layers the settings file cannot outrank. Editing there would write a value nobody
    /// reads, so the row offers no control at all.
    @Test("a key from the environment or WORKLENS_ENV_FILE is not editable here")
    func lockedLayers() {
        var config = Config.defaults(cwd: URL(fileURLWithPath: "/tmp"))
        config.geminiAPIKey = "AIzaSomething"

        for layer in [ConfigLayer.process, .explicitFile] {
            let row = Accounts.row(
                .gemini, config: config,
                provenance: ConfigProvenance(sources: ["GEMINI_API_KEY": layer])
            )
            #expect(!row.isEditable)
            #expect(row.sourceNote?.contains("nothing to change here") == true)
        }
    }

    // MARK: Entry

    @Test("a pasted key is trimmed, and an impossible one is refused")
    func entryRules() {
        #expect(Accounts.normalize("  sk-ant-abc\n") == "sk-ant-abc")
        #expect(Accounts.entryError("  sk-ant-abc\n") == nil)
        #expect(Accounts.entryError("   ") != nil)
        #expect(Accounts.entryError("sk-ant abc")?.contains("space in the middle") == true)
    }

    /// Shape is a caption, never a refusal — a window that rejects a working key because a provider changed its prefix is worse than one
    /// that says so and saves it.
    @Test("the shape check warns about a prefix and refuses nothing")
    func shapeWarning() {
        #expect(Accounts.shapeWarning(.gemini, "AIzaSyQ") == nil)
        #expect(Accounts.shapeWarning(.gemini, "sk-ant-xyz")?.contains("AIza") == true)
        // Empty is `entryError`'s business, not this one's.
        #expect(Accounts.shapeWarning(.gemini, "") == nil)
    }

    // MARK: One paste, one step (#246)

    /// The sequence the field used to hold in six `@State` variables: save, say what the shape
    /// looks like, ask the provider. A key with the right prefix saves and is asked about with
    /// nothing to read yet — the provider's answer is the sentence.
    @Test("a pasted key is saved and asked about in one action")
    func entryVerifiesWhatItSaves() {
        let entry = Accounts.entry("  AIzaSyQ-whole-key \n", for: .gemini)
        #expect(entry.key == "AIzaSyQ-whole-key")
        #expect(entry.verifies)
        #expect(entry.caption == nil)
    }

    /// A wrong prefix warns inline and still saves — providers change their prefixes — and is
    /// still asked about, because only the provider settles it.
    @Test("the wrong prefix warns inline, saves anyway and still asks")
    func entryWarnsOnShape() throws {
        let entry = Accounts.entry("sk-ant-api03-xyz", for: .gemini)
        #expect(entry.key == "sk-ant-api03-xyz")
        #expect(entry.verifies)
        let caption = try #require(entry.caption)
        #expect(caption.level == .attention)
        #expect(caption.text.contains("AIza"))
        #expect(caption.text.contains("saved"))
        // Never a fragment of what was pasted.
        #expect(!caption.text.contains("xyz"))
    }

    /// Nothing saveable saves nothing and asks nobody: the field stays open on what was typed.
    @Test("a value that cannot be a key saves nothing and asks nothing")
    func entryRefuses() throws {
        for typed in ["   ", "sk-ant abc"] {
            let entry = Accounts.entry(typed, for: .gemini)
            #expect(entry.key == nil)
            #expect(!entry.verifies)
            #expect(try #require(entry.caption).level == .problem)
        }
    }

    /// What separates a paste from typing. A person cannot type a whole key between two
    /// `onChange`s, and a field that already holds something is being edited, not pasted into.
    @Test("a whole key arriving at once is a paste; typing is not")
    func looksPasted() {
        #expect(Accounts.looksPasted(from: "", to: "AIzaSyQ-a-whole-long-key"))
        #expect(!Accounts.looksPasted(from: "", to: "A"))
        #expect(!Accounts.looksPasted(from: "", to: "AIzaSyQ"))
        #expect(!Accounts.looksPasted(from: "AIzaSyQ-a-whole-long-ke", to: "AIzaSyQ-a-whole-long-key"))
        #expect(!Accounts.looksPasted(from: "", to: "   "))
    }

    /// One sentence per outcome, each naming the provider and — where there is one — the HTTP
    /// status the ledger row carries. Never a fragment of the key.
    @Test("each verdict is one sentence, with a status and no key")
    func verdictSentences() {
        let accepted = Accounts.verdict(
            AccountVerification(provider: .gemini, verdict: .accepted, httpStatus: 200))
        #expect(accepted.level == .ok)
        #expect(accepted.text.contains("recognises this key"))

        let rejected = Accounts.verdict(
            AccountVerification(provider: .gemini, verdict: .rejected("forbidden"), httpStatus: 403))
        #expect(rejected.level == .problem)
        #expect(rejected.text.contains("403"))
        #expect(rejected.text.contains("billing"))

        let unreachable = Accounts.verdict(
            AccountVerification(provider: .gemini, verdict: .unreachable("offline"), httpStatus: nil))
        #expect(unreachable.level == .attention)
        #expect(unreachable.text.contains("network problem"))
        for caption in [accepted, rejected, unreachable] {
            #expect(!caption.text.contains("AIza"))
            #expect(!caption.text.contains("sk-ant-"))
        }
    }

    /// **Verify** is for the key there was no paste to hook onto.
    @Test("only a key from outside Worklens's own store keeps a Verify button")
    func verifyButtonIsForKeysFromElsewhere() {
        func row(_ source: ConfigLayer, isSet: Bool = true) -> AccountRow {
            AccountRow(provider: .gemini, masked: "AIzaSyQ…", isSet: isSet, source: source)
        }
        #expect(!row(.appSettings).offersVerify)
        #expect(row(.appSupport).offersVerify)
        #expect(row(.cwd).offersVerify)
        #expect(row(.process).offersVerify)
        #expect(row(.explicitFile).offersVerify)
        #expect(!row(.fallback, isSet: false).offersVerify)
    }

    // MARK: Precedence

    /// The question #124 had to answer: a key typed in Settings versus the same key in a `.env`.
    /// The store beats both files and loses to the two layers a worktree or a script pins (#34).
    @Test("the settings store outranks both .env files and loses to the environment")
    func precedence() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cwd = dir.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let appSupportEnv = dir.appendingPathComponent("app-support.env")
        let settingsFile = dir.appendingPathComponent("settings.json")
        let explicitFile = dir.appendingPathComponent("pinned.env")

        try write("GEMINI_API_KEY=AIza-from-cwd\n", to: cwd.appendingPathComponent(".env"))
        try write("GEMINI_API_KEY=AIza-from-app-support\n", to: appSupportEnv)
        try SettingsStore(url: settingsFile).set("GEMINI_API_KEY", "AIza-from-settings")

        func load(_ environment: [String: String]) throws -> (Config, ConfigProvenance) {
            try Config.loadWithProvenance(
                environment: environment, cwd: cwd,
                appSupportEnv: appSupportEnv, settingsFile: settingsFile
            )
        }

        let (settingsWins, settingsProvenance) = try load([:])
        #expect(settingsWins.geminiAPIKey == "AIza-from-settings")
        #expect(settingsProvenance.source(of: "GEMINI_API_KEY") == .appSettings)

        let (envWins, envProvenance) = try load(["GEMINI_API_KEY": "AIza-from-env"])
        #expect(envWins.geminiAPIKey == "AIza-from-env")
        #expect(envProvenance.source(of: "GEMINI_API_KEY") == .process)

        try write("GEMINI_API_KEY=AIza-from-pinned-file\n", to: explicitFile)
        let (fileWins, fileProvenance) = try load(["WORKLENS_ENV_FILE": explicitFile.path])
        #expect(fileWins.geminiAPIKey == "AIza-from-pinned-file")
        #expect(fileProvenance.source(of: "GEMINI_API_KEY") == .explicitFile)

        // And the row says which of them the user is looking at.
        #expect(!Accounts.row(.gemini, config: fileWins, provenance: fileProvenance).isEditable)
        #expect(Accounts.row(.gemini, config: settingsWins, provenance: settingsProvenance).isStored)
    }

    /// The post-rotation case `appSupportOverrides` warns about (#34): once the key is set in
    /// Settings, the App Support file is no longer taking anything away from the checkout, so
    /// the "these files disagree" line must not be permanent.
    @Test("a key set in Settings ends the files-disagree warning")
    func settingsEndsTheOverrideWarning() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cwd = dir.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let appSupportEnv = dir.appendingPathComponent("app-support.env")
        let settingsFile = dir.appendingPathComponent("settings.json")

        try write("GEMINI_API_KEY=AIzaFromCheckout\n", to: cwd.appendingPathComponent(".env"))
        try write("GEMINI_API_KEY=AIzaFromAppSupport\n", to: appSupportEnv)

        let before = try Config.loadWithProvenance(
            environment: [:], cwd: cwd, appSupportEnv: appSupportEnv, settingsFile: settingsFile
        )
        #expect(before.provenance.appSupportOverrides.contains("GEMINI_API_KEY"))

        try SettingsStore(url: settingsFile).set("GEMINI_API_KEY", "AIzaTypedInSettings")
        let after = try Config.loadWithProvenance(
            environment: [:], cwd: cwd, appSupportEnv: appSupportEnv, settingsFile: settingsFile
        )
        #expect(after.config.geminiAPIKey == "AIzaTypedInSettings")
        #expect(after.provenance.appSupportOverrides.isEmpty)
    }

    @Test("the settings file that holds a key is 0600")
    func storedKeyIsPrivate() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))

        try store.set("GEMINI_API_KEY", "AIza-abc")
        let mode = try FileManager.default
            .attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)

        try store.remove("GEMINI_API_KEY")
        #expect(store.get("GEMINI_API_KEY") == nil)
    }

    // MARK: Verify

    /// Answers from a dictionary. `make test` makes no network call — not once, not behind a flag.
    private struct FakeProbes: KeyProbing, @unchecked Sendable {
        var probe: KeyProbe = KeyProbe(verdict: .accepted, httpStatus: 200, latencyMs: 12)
        let seen = Seen()

        final class Seen: @unchecked Sendable {
            var providers: [KeyProvider] = []
        }

        func probeKey(_ provider: KeyProvider, key: String) async -> KeyProbe {
            seen.providers.append(provider)
            return probe
        }
    }

    private final class Recorded: @unchecked Sendable {
        var calls: [LLMCall] = []
    }

    @Test("an accepted key writes a free ledger row and reads as OK")
    func verifyAccepted() async {
        let recorded = Recorded()
        let verifier = AccountVerifier(
            probes: FakeProbes(),
            record: { call in recorded.calls.append(call) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            identifier: { "verify-1" }
        )

        let verification = await verifier.verify(.gemini, key: "AIzaSomething")
        #expect(verification.verdict == .accepted)
        #expect(verification.line == "OK")
        #expect(verification.status == .ok)

        #expect(recorded.calls.count == 1)
        let row = try! #require(recorded.calls.first)
        #expect(row.purpose == .verify)
        #expect(row.provider == "gemini")
        #expect(row.model == AccountVerifier.endpointName)
        #expect(row.costUsd == 0)
        #expect(row.promptTokens == 0)
        #expect(row.outputTokens == 0)
        #expect(row.httpStatus == 200)
        #expect(row.error == nil)
        #expect(!row.isFailure)
    }

    @Test("a refused key records the status and nothing else")
    func verifyRejected() async {
        let recorded = Recorded()
        var probes = FakeProbes()
        probes.probe = KeyProbe(
            verdict: .rejected("HTTP 401: the provider refused this key"),
            httpStatus: 401, latencyMs: 30
        )
        let verifier = AccountVerifier(
            probes: probes,
            record: { call in recorded.calls.append(call) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            identifier: { "verify-2" }
        )

        let verification = await verifier.verify(.gemini, key: "AIza-wrong")
        #expect(verification.line == "Rejected: HTTP 401")
        #expect(verification.status == .problem)

        let row = try! #require(recorded.calls.first)
        #expect(row.purpose == .verify)
        #expect(row.costUsd == 0)
        #expect(row.httpStatus == 401)
        // The status, and not one word of the provider's own message.
        #expect(row.error == "HTTP 401")
        #expect(row.isFailure)
    }

    @Test("no answer at all is not the key's fault, and carries no status")
    func verifyUnreachable() async {
        let recorded = Recorded()
        var probes = FakeProbes()
        probes.probe = KeyProbe(verdict: .unreachable("offline"), httpStatus: nil, latencyMs: 5)
        let verifier = AccountVerifier(
            probes: probes, record: { call in recorded.calls.append(call) }
        )

        let verification = await verifier.verify(.gemini, key: "AIzaSomething")
        #expect(verification.status == .attention)
        #expect(verification.line == "Could not reach the provider")

        let row = try! #require(recorded.calls.first)
        #expect(row.httpStatus == nil)
        #expect(row.error == "unreachable")
        #expect(row.costUsd == 0)
    }

    /// A $0 purpose must not move a cost table, and must not be stopped by the budget: a person
    /// pressed the button, and the call bills nothing.
    @Test("verify costs nothing, anywhere")
    func verifyCostsNothing() {
        #expect(CostTracker.firstGuess(.verify) == 0)
        #expect(CostPolicy.allowsOverdraft(.verify, userInitiated: true))
        #expect(CostPolicy.allowsOverdraft(.verify, userInitiated: false))

        let day = DailySpend(
            day: "2026-09-14", costUsd: 0.5, calls: 3, failures: 1,
            purposes: [
                PurposeSpend(purpose: .describe, costUsd: 0.5, calls: 2),
                PurposeSpend(purpose: .verify, costUsd: 0, calls: 1, failures: 1),
            ]
        )
        #expect(day.describeUSD + day.reportsUSD + day.otherUSD == day.costUsd)
        #expect(day.usd(.verify) == 0)
    }

    /// `purpose` is a plain `TEXT` column, so the new case needs no migration — but its spelling
    /// is now persisted, and changing it later would orphan every row already written.
    @Test("the persisted spelling of the new purpose is verify")
    func purposeRawValue() {
        #expect(LLMPurpose.verify.rawValue == "verify")
        #expect(LLMPurpose(rawValue: "verify") == .verify)
        #expect(LLMPurpose.allCases.contains(.verify))
    }
}
