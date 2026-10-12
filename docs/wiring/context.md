# The context sources in the app shell (#15 × #19–#22)

Issues #19–#22 landed while the menu-bar UI (#15) was still open, so this file used to be a
list of lines to add. #15 is merged and those lines are in place — what follows is where they
are, and the two things still worth doing.

## Done

**Settings → Integrations.** `SettingsView` renders `IntegrationsSettingsView(model: model)`.
It used to be handed a `Config` snapshot and the scheduler, and a `@StateObject` kept both across
every reload — so the pane drew a configuration that had been replaced and called a scheduler that
had been stopped (#135). It now holds the `AppModel` weakly, reads `config` and `contextSync` at
the moment it asks, and refreshes when `AppModel.configGeneration` changes.

**The sync scheduler runs with the app.** `AppModel.buildServices()` builds
`ContextSyncScheduler` over `ContextSources.all(config:)` and hands it the *same*
`MeetingDetector` instance the `CaptureScheduler` holds, via
`onMeetings: { events in await meeting.setContextEvents(events) }`. That closure is what makes
capture drop to `MEETING_CAPTURE_INTERVAL_SECONDS` during a scheduled meeting, rather than only
when a meeting app is in the foreground. `AppModel.start()` starts it, `shutdown()` stops it, and
`reloadConfig()` rebuilds it — and, when the change is confined to the context keys
(`ConfigReload.onlyContextChanged`), rebuilds *only* it, leaving capture and the describe worker
running (#135). The app is the only place it is built: the CLI scheduler that also built one went in #300.
It is also handed `outputs: OutputSync.forConfig(config, db: db)` (#314), nil when
`GITHUB_SHIPPED=false`; each round awaits `outputs.syncIfDue()` before `onMeetings`, and that
call keeps its own backoff, so a missing or logged-out `gh` never slows the meeting sources.

## Done in the review pass (2026-09)

**A Connect button for Google.** Settings → Integrations has a "Google account" section:
"Connect Google…" runs `GoogleAuth.connect()` (system browser, loopback redirect), shows the
connected address with a "Disconnect" button afterwards, and shows the failure inline when the
flow is declined, times out or the client id is missing. `IntegrationsModel.google` is the state
behind it. The Calendar row's hint now says "Connect Google below" instead of naming
the CLI.

**Not a menu item any more.** The popover offered "Set up integrations…" while
`AppModel.hasConfiguredIntegrations` was false — `ContextSources.configured(config:)` is empty.
#231's menu drops that row: Settings → Integrations is the pane the offer pointed at, and the one
integration line the menu keeps is the attention row `MenuModel.integrationAttentionLine` raises
when a source's token was refused. #136 had already deleted the "Sync integrations now" sibling;
Settings → Integrations has "Sync all now", and that is where a per-source failure is shown.

## Nothing else is needed

The timeline writer and the stats aggregator read `context_events` on their own; no UI change is involved in any of that.

## The setup sheet (#135)

Everything Settings → Integrations says about setting a source up is a value in
`WorklensCore/Context/IntegrationSetup.swift`: the value sentence, the "What is stored" rows (the
same claims as `PRIVACY.md`, checked against its table by a test), the numbered steps and the two
pages they link to, and the per-field paste rules. `IntegrationTester` is the Test button —
`GranolaSource.check` (one note), which writes nothing to the database. Credentials are saved with `AppModel.applySetting`, which
is `SettingsStore`; a field whose key the process environment or `WORKLENS_ENV_FILE` supplies shows
itself disabled, because writing it would change a file nothing reads.
