import Foundation
import Testing
@testable import WorklensCore

// MARK: - Fixtures

private func granolaField() -> IntegrationField {
    IntegrationSetup.fields(for: .granola)[0]
}

private func configuredConfig() -> Config {
    var config = Config.defaults()
    config.granolaAPIKey = "grn_live"
    return config
}

// MARK: - What a card says

@Suite("Integration setup cards")
struct IntegrationSetupCardTests {
    @Test("every source has a value sentence, a stored disclosure and numbered steps")
    func everySourceIsDescribed() {
        for source in ContextSource.allCases {
            #expect(!IntegrationSetup.value(for: source).isEmpty)
            #expect(IntegrationSetup.stored(for: source).count >= 2,
                    "\(source.rawValue) must say both what is sent and what is kept")
            let steps = IntegrationSetup.steps(for: source)
            #expect(!steps.isEmpty)
            #expect(steps.map(\.number) == Array(1...steps.count), "steps are numbered in order")
            #expect(steps.allSatisfy { !$0.text.isEmpty })
        }
    }

    @Test("the Granola plan requirement is stated before any key is pasted")
    func granolaStatesThePlanFirst() {
        let requirement = IntegrationSetup.requirement(for: .granola)
        #expect(requirement?.contains("Business plan") == true)
        // Calendar has nothing that has to be bought first, and inventing a note for it would
        // train the reader to skip this one.
        #expect(IntegrationSetup.requirement(for: .calendar) == nil)
    }

    @Test("what a card claims is sent names the host PRIVACY.md documents")
    func hostsAreDocumented() throws {
        let table = try NetworkDestinationsDocTests.destinationsTable()
        for source in ContextSource.allCases {
            let host = IntegrationSetup.host(for: source)
            #expect(table.contains(host),
                    "PRIVACY.md's destinations table does not name \(host)")
            #expect(IntegrationSetup.stored(for: source).contains { $0.contains(host) },
                    "the \(source.rawValue) disclosure must name the host it reaches")
        }
    }

    @Test("the setup links have a row of their own in PRIVACY.md")
    func setupLinksAreDocumented() throws {
        let table = try NetworkDestinationsDocTests.destinationsTable()
        for url in [IntegrationSetup.Links.googleCloud, IntegrationSetup.Links.googleCredentials] {
            let host = try #require(url.host())
            #expect(table.contains(host), "PRIVACY.md does not mention the setup link \(host)")
        }
    }

    @Test("a step's link reads as its host, without the scheme")
    func linkLabels() {
        let step = IntegrationSetup.steps(for: .calendar)[0]
        #expect(step.link == IntegrationSetup.Links.googleCloud)
        #expect(step.linkLabel == "console.cloud.google.com")
        #expect(IntegrationStep(number: 1, text: "x").linkLabel == nil)
    }

    @Test("only Granola can be tested; Google is proved by connecting")
    func testableSources() {
        #expect(IntegrationSetup.isTestable(.granola))
        #expect(!IntegrationSetup.isTestable(.calendar))
    }

    @Test("the Google card says once that an older grant's mail access can be removed (#285)")
    func googleCardMentionsTheOldMailGrant() {
        let stored = IntegrationSetup.stored(for: .calendar)
        #expect(stored.filter { $0.contains("myaccount.google.com/permissions") }.count == 1)
    }
}

// MARK: - Pasting

@Suite("Integration credential entry")
struct IntegrationEntryTests {
    @Test("a key is accepted around its whitespace, with no warning")
    func acceptsAKey() {
        #expect(IntegrationSetup.entryError(granolaField(), " grn_123\n") == nil)
        #expect(IntegrationSetup.shapeWarning(granolaField(), "grn_123") == nil)
    }

    @Test("nothing typed, and a paste that picked up a sentence, are both refused")
    func refusesUnusableValues() {
        #expect(IntegrationSetup.entryError(granolaField(), "   ") != nil)
        #expect(IntegrationSetup.entryError(granolaField(), "grn_abc def") != nil)
    }

    @Test("a wrong-looking prefix is a warning, not a refusal, and names the key")
    func shapeIsAWarning() {
        #expect(IntegrationSetup.entryError(granolaField(), "abc123") == nil)
        let warning = IntegrationSetup.shapeWarning(granolaField(), "abc123")
        #expect(warning?.contains("GRANOLA_API_KEY") == true)
        #expect(warning?.contains("grn_") == true)
        #expect(IntegrationSetup.shapeWarning(granolaField(), "grn_abc") == nil)
    }

    @Test("the note shown while you type claims no save, and names the field rather than the key")
    func liveNoteIsPresentTense() {
        let note = IntegrationSetup.shapeNote(granolaField(), "abc123")
        #expect(note?.contains("Saved") == false)
        #expect(note?.contains("GRANOLA_API_KEY") == false)
        #expect(note?.contains(granolaField().label) == true)
        #expect(note?.contains("grn_") == true)
        #expect(IntegrationSetup.shapeNote(granolaField(), "grn_abc") == nil)
    }

    @Test("the Google fields check the shapes those two credentials actually have (#139)")
    func googleFieldsCheckTheirShape() {
        let fields = IntegrationSetup.fields(for: .calendar)
        let clientID = try! #require(fields.first { $0.key == "GOOGLE_CLIENT_ID" })
        let secret = try! #require(fields.first { $0.key == "GOOGLE_CLIENT_SECRET" })

        // A client id has no stable prefix, but it always ends the same way.
        #expect(clientID.expectedPrefix == nil)
        #expect(clientID.expectedSuffix == ".apps.googleusercontent.com")
        #expect(IntegrationSetup.shapeNote(clientID, "123-abc.apps.googleusercontent.com") == nil)
        #expect(IntegrationSetup.shapeNote(clientID, "123-abc")?.contains(
            ".apps.googleusercontent.com") == true)
        // The commonest paste error: the secret into the id field. Refused, not warned about.
        #expect(IntegrationSetup.entryError(clientID, "GOCSPX-abc")?.contains("client secret")
            == true)

        #expect(secret.expectedPrefix == "GOCSPX-")
        #expect(IntegrationSetup.shapeNote(secret, "GOCSPX-abc") == nil)
        #expect(IntegrationSetup.shapeNote(secret, "abc")?.contains("GOCSPX-") == true)
    }

    @Test("the Google steps link straight to the console pages they name (#139)")
    func googleStepsCarryDeepLinks() {
        let steps = IntegrationSetup.steps(for: .calendar)
        let links = steps.compactMap(\.link).map(\.absoluteString)
        #expect(links.contains { $0.contains("library/calendar-json.googleapis.com") })
        #expect(!links.contains { $0.contains("gmail") }, "#285: the Gmail API is not needed")
        #expect(links.contains { $0.contains("credentials/consent") })
        // Every step that sends you somewhere says where, rather than showing a bare URL.
        #expect(steps.filter { $0.link != nil }.allSatisfy { $0.linkLabel?.isEmpty == false })
    }

    @Test("the seven-day expiry is stated in the sheet's own words (#139)")
    func testingScreenNoteSaysSevenDays() {
        let note = IntegrationSetup.googleTestingNote
        #expect(note.contains("7 days"))
        #expect(note.contains("Testing"))
        #expect(note.contains("Reconnect"))
        // The whole point: no terminal command in a sentence a menu-bar user reads.
        #expect(!note.lowercased().contains("worklens google connect"))
    }

    @Test("a rejected Google request points at the button, not the terminal (#139)")
    func unauthorizedHintNamesTheButton() {
        for api in ["Calendar"] {
            let hint = IntegrationSetup.googleUnauthorizedHint(api)
            #expect(hint.contains(api))
            #expect(hint.contains("Reconnect"))
            // It is drawn verbatim on the card and in the menu, where there is no terminal.
            #expect(!hint.lowercased().contains("worklens google connect"))
        }
    }

    @Test("a paused Google source says so, and offers the one click that fixes it (#139)")
    func pausedCardReadsAsPaused() {
        let status = SourceStatus(
            id: .calendar,
            displayName: "Calendar",
            isConfigured: true,
            lastError: "Your Google sign-in expired — reconnect to start syncing again.",
            lastErrorWasCredential: true,
            needsReconnect: true
        )
        let card = IntegrationCards.card(
            source: .calendar, displayName: "Calendar", isConfigured: true, status: status
        )
        #expect(card.detail == "Paused until you reconnect")
        #expect(card.statusText == "Sign in again")
        // Amber, not red: nothing is broken, the seven days simply ran out.
        #expect(card.level == .attention)

        // Without the flag the same status is still an ordinary failure line.
        var plain = status
        plain.needsReconnect = false
        let failed = IntegrationCards.card(
            source: .calendar, displayName: "Calendar", isConfigured: true, status: plain
        )
        #expect(failed.detail != "Paused until you reconnect")
    }

    @Test("the token store is a choice with two sentences, pre-selected by the signature (#139)")
    func tokenStoreChoice() {
        // No Apple Developer Team ID in the signature — every build of Worklens today — means the
        // login keychain would ask for the login password after every rebuild.
        #expect(GoogleTokenStorage.recommended(teamID: nil) == .file)
        #expect(GoogleTokenStorage.recommended(teamID: "") == .file)
        #expect(GoogleTokenStorage.recommended(teamID: "ABCDE12345") == .keychain)

        for store in GoogleTokenStorage.allCases {
            #expect(!store.label.isEmpty)
            #expect(!store.detail.isEmpty)
            // The sentence names the trade, in words, without an environment variable in it.
            #expect(!store.detail.contains("GOOGLE_TOKEN_STORE"))
        }
        #expect(GoogleTokenStorage.file.detail.contains("0600"))
        #expect(GoogleTokenStorage.keychain.detail.contains("login password"))
    }

    @Test("no sentence a field produces ever quotes the value")
    func sentencesNeverCarryTheValue() {
        let clientID = IntegrationSetup.fields(for: .calendar)[0]
        let problem = IntegrationSetup.entryError(clientID, "GOCSPX-000-shouldnotappear") ?? ""
        #expect(!problem.contains("shouldnotappear"))
        let warning = IntegrationSetup.shapeWarning(granolaField(), "nope-shouldnotappear") ?? ""
        #expect(!warning.contains("shouldnotappear"))
        let note = IntegrationSetup.shapeNote(granolaField(), "nope-shouldnotappear") ?? ""
        #expect(!note.contains("shouldnotappear"))
    }

    @Test("every field names a real config key Worklens is allowed to write")
    func fieldsAreWritableKeys() {
        for source in ContextSource.allCases {
            for field in IntegrationSetup.fields(for: source) {
                let entry = Config.key(named: field.key)
                #expect(entry != nil, "\(field.key) is not in the config registry")
                #expect(entry?.editableInApp == true,
                        "\(field.key) must be writable from the app for the sheet to save it")
            }
        }
    }

    @Test("the sync interval is writable from the app too")
    func intervalIsWritable() {
        #expect(Config.key(named: "CONTEXT_SYNC_MINUTES")?.editableInApp == true)
    }

    @Test("a field reads back the value its key holds")
    func storedValues() {
        let config = configuredConfig()
        #expect(IntegrationSetup.storedValue(granolaField(), in: config) == "grn_live")
        #expect(IntegrationSetup.storedValue(granolaField(), in: Config.defaults()) == nil)
    }

    @Test("a layer above the settings file disables the control instead of lying about it")
    func lockedLayers() {
        #expect(!ConfigLayer.process.isWritableInApp)
        #expect(!ConfigLayer.explicitFile.isWritableInApp)
        #expect(ConfigLayer.process.lockedNote?.contains("environment") == true)
        #expect(ConfigLayer.explicitFile.lockedNote?.contains("WORKLENS_ENV_FILE") == true)
        for layer in [ConfigLayer.appSettings, .appSupport, .cwd, .fallback] {
            #expect(layer.isWritableInApp)
            #expect(layer.lockedNote == nil)
        }
    }
}

// MARK: - The cards

@Suite("Integration card states")
struct IntegrationCardStateTests {
    @Test("one card per source, in the order the sources are declared")
    func oneCardPerSource() {
        let cards = IntegrationCards.build(config: Config.defaults(), statuses: [])
        #expect(cards.map(\.source) == [.granola, .calendar])
        // The old pane showed an empty state telling the reader to edit a file. There is no
        // configuration in which this pane has nothing to show.
        #expect(!cards.isEmpty)
    }

    @Test("a source with no credential is greyed, not red")
    func notSetUp() throws {
        let cards = IntegrationCards.build(config: Config.defaults(), statuses: [])
        let granola = try #require(cards.first { $0.source == .granola })
        #expect(granola.state == .notSetUp)
        #expect(granola.level == .muted)
        #expect(granola.statusText == "Not set up")
        #expect(granola.setUpTitle == "Set up\u{2026}")
    }

    @Test("a configured source that has never synced reads as connected")
    func connected() throws {
        let cards = IntegrationCards.build(config: configuredConfig(), statuses: [])
        let granola = try #require(cards.first { $0.source == .granola })
        #expect(granola.state == .connected)
        #expect(granola.level == .ok)
        #expect(granola.setUpTitle == "Change\u{2026}")
    }

    @Test("a refused credential is its own state, and Granola's names the plan")
    func refused() {
        let status = SourceStatus(
            id: .granola,
            displayName: "Granola",
            isConfigured: true,
            lastError: GranolaSource.authHint,
            lastErrorWasCredential: true
        )
        let card = IntegrationCards.card(
            source: .granola, displayName: "Granola", isConfigured: true, status: status
        )
        #expect(card.state == .refused)
        #expect(card.level == .attention, "a credential to re-paste is not a red error")
        #expect(card.statusText == "Key or plan not accepted")
        #expect(card.detail == GranolaSource.authHint)
    }

    @Test("anything else the last sync hit stays a problem")
    func failed() {
        let status = SourceStatus(
            id: .granola,
            displayName: "Granola",
            isConfigured: true,
            lastError: "rate limited",
            lastErrorWasCredential: false,
            lastWarnings: ["one page failed"]
        )
        let card = IntegrationCards.card(
            source: .granola, displayName: "Granola", isConfigured: true, status: status
        )
        #expect(card.state == .failed)
        #expect(card.level == .problem)
        #expect(card.warnings == ["one page failed"])
    }

    @Test("a state's colour is decided once, in WorklensCore")
    func levels() {
        #expect(IntegrationState.notSetUp.level == .muted)
        #expect(IntegrationState.connected.level == .ok)
        #expect(IntegrationState.refused.level == .attention)
        #expect(IntegrationState.failed.level == .problem)
    }
}

// MARK: - Which failures are the credential's

@Suite("Credential failures")
struct CredentialFailureTests {
    @Test("a refused or missing credential is told from a transport problem")
    func classifiesContextErrors() {
        #expect(ContextSyncError.isCredential(ContextSyncError.unauthorized("no")))
        #expect(ContextSyncError.isCredential(ContextSyncError.notConfigured("SLACK_USER_TOKEN")))
        #expect(!ContextSyncError.isCredential(ContextSyncError.rateLimited(retryAfter: 30)))
        #expect(!ContextSyncError.isCredential(ContextSyncError.http(503, "down")))
        #expect(!ContextSyncError.isCredential(ContextSyncError.decode("nope")))
        #expect(!ContextSyncError.isCredential(URLError(.notConnectedToInternet)))
    }

    @Test("Google's own failures count as the credential too")
    func classifiesGoogleFailures() {
        #expect(ContextSyncError.isCredential(GoogleAuth.Failure.notConnected))
        #expect(ContextSyncError.isCredential(GoogleAuth.Failure.invalidGrant))
        #expect(!ContextSyncError.isCredential(GoogleAuth.Failure.stateMismatch))
    }
}
