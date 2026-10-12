## What and why

<!-- One or two sentences. Link the issue: "Closes #NN". One issue per pull request. -->

Closes #

## How it was verified

<!-- Paste the test count line, e.g. "Test run with 936 tests in 144 suites passed". -->

- [ ] `make test` is green (count: )
- [ ] Verified against the running app where the change is visible in the UI
- [ ] CI is green (or the failing step is explained above)

## Checklist

- [ ] Scoped to one issue; no drive-by refactors
- [ ] `docs/architecture.md` updated if a type, table or config key moved or appeared
- [ ] A new config key is a `ConfigKey` entry plus its `Config` property, and `.env.example` was
      regenerated with `swift run Worklens config-example > .env.example`, not hand-edited
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` if this is visible to someone running the app
- [ ] No new dependency, or the reason for one is in the description

## Privacy

- [ ] Nothing new is captured, kept or sent — **or** `PRIVACY.md` is updated in this PR to say what is
- [ ] No screenshot contents, window titles, URLs or API keys are logged at `info` level or above
- [ ] Reports and prompts still address the user as "you", with no scores, rankings or comparisons
