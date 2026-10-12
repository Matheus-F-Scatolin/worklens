import Foundation

// MARK: - The registry

public extension Config {
    /// Every key Worklens knows, in `.env.example` order, retired ones last.
    ///
    /// This is the single list. `load(layers:cwd:)` dispatches over it, `dumpLines` is it,
    /// `retiredKeys` is its tail, `EnvExample.render()` prints it, and `SettingsStore` asks it
    /// what may be written and whether a value parses. Adding a key is one entry here plus
    /// its property on `Config`.
    static let keys: [ConfigKey] =
        credentialKeys + describeKeys + captureKeys + privacyKeys
            + budgetKeys + contextKeys + updateKeys + retiredEntries

    /// The live keys, in registry order: everything `config-dump` prints.
    static var liveKeys: [ConfigKey] { keys.filter { !$0.retired } }

    /// The entry for a key name, live or retired.
    static func key(named name: String) -> ConfigKey? { keys.first { $0.name == name } }
}

// MARK: - Credentials

private extension Config {
    static let credentialKeys: [ConfigKey] = [
        ConfigKey(
            name: "GEMINI_API_KEY",
            section: .credentials,
            kind: .secret,
            default: "",
            help: "Gemini, used for the cheap per-screenshot description pass.",
            docs: """
                Gemini, used for the cheap per-screenshot description pass.
                Use a BILLING-ENABLED project: on the free tier Google may train on your prompts and images.
                """,
            apply: { c, v, _ in c.geminiAPIKey = v },
            read: { Config.mask($0.geminiAPIKey) }
        ),
    ]

    static let describeKeys: [ConfigKey] = [
        ConfigKey(
            name: "DESCRIBE_MODEL",
            section: .describe,
            kind: .model,
            default: "gemini-3.5-flash-lite",
            help: "Vision model id.",
            apply: { c, v, _ in c.describeModel = v },
            read: { $0.describeModel }
        ),
        // The name is from when it also set the reports' language; they were cut on 2026-10-05
        // and the key kept its name so an existing `.env` keeps working.
        ConfigKey(
            name: "REPORT_LANGUAGE",
            section: .describe,
            kind: .string,
            default: "en",
            help: "Language the summaries are written in, as a BCP-47 code.",
            docs: """
                The language the model writes each screenshot's summary in: an IETF code such as `en`,
                `pt-BR` or `de`. At its default, `en`, nothing is added to the prompt; any other value
                appends one sentence to the describe prompt asking for that language, while keys, slugs,
                app names and every identifier stay in English so the timeline and the stats still line
                up. It is deliberately not derived from your Mac's language: a default that changed with
                System Settings would change what the prompt says from one machine to the next.
                """,
            apply: { c, v, _ in c.reportLanguage = v },
            read: { $0.reportLanguage }
        ),
    ]
}

// MARK: - Capture

private extension Config {
    static let captureKeys: [ConfigKey] = [
        ConfigKey(
            name: "CAPTURE_INTERVAL_SECONDS",
            section: .capture,
            kind: .int,
            default: "60",
            help: "Seconds between screenshots while you are working. 5 to 600.",
            minimum: 5,
            maximum: 600,
            apply: { c, v, _ in
                c.captureIntervalSeconds = try Config.int("CAPTURE_INTERVAL_SECONDS", v, default: c.captureIntervalSeconds)
            },
            read: { String($0.captureIntervalSeconds) }
        ),
        ConfigKey(
            name: "MEETING_CAPTURE_INTERVAL_SECONDS",
            section: .capture,
            kind: .int,
            default: "300",
            help: "Slower cadence while a meeting is detected. 5 to 900.",
            minimum: 5,
            maximum: 900,
            apply: { c, v, _ in
                c.meetingCaptureIntervalSeconds = try Config.int(
                    "MEETING_CAPTURE_INTERVAL_SECONDS", v, default: c.meetingCaptureIntervalSeconds
                )
            },
            read: { String($0.meetingCaptureIntervalSeconds) }
        ),
        ConfigKey(
            name: "CAPTURE_IDLE_SECONDS",
            section: .capture,
            kind: .int,
            default: "120",
            help: "No input for this many seconds counts as idle; captures pause. 5 to 1800.",
            minimum: 5,
            maximum: 1800,
            apply: { c, v, _ in
                c.captureIdleSeconds = try Config.int("CAPTURE_IDLE_SECONDS", v, default: c.captureIdleSeconds)
            },
            read: { String($0.captureIdleSeconds) }
        ),
        ConfigKey(
            name: "CAPTURE_HEARTBEAT_SECONDS",
            section: .capture,
            kind: .int,
            default: "300",
            help: "Describe a screenshot at least this often even when nothing changed. 5 to 3600.",
            minimum: 5,
            maximum: 3600,
            apply: { c, v, _ in
                c.captureHeartbeatSeconds = try Config.int("CAPTURE_HEARTBEAT_SECONDS", v, default: c.captureHeartbeatSeconds)
            },
            read: { String($0.captureHeartbeatSeconds) }
        ),
        ConfigKey(
            name: "CHANGE_THRESHOLD",
            section: .capture,
            kind: .unitDouble,
            default: "0.03",
            help: "Skip the vision call when the screen changed less than this fraction (0-1).",
            apply: { c, v, _ in
                c.changeThreshold = try Config.unitDouble("CHANGE_THRESHOLD", v, default: c.changeThreshold)
            },
            read: { String($0.changeThreshold) }
        ),
        ConfigKey(
            name: "CAPTURE_MAX_EDGE_PX",
            section: .capture,
            kind: .int,
            default: "1024",
            help: "Downscale the longest edge to this many pixels before storing/sending. 64 to 4096.",
            minimum: 64,
            maximum: 4096,
            apply: { c, v, _ in
                c.captureMaxEdgePx = try Config.int("CAPTURE_MAX_EDGE_PX", v, default: c.captureMaxEdgePx)
            },
            read: { String($0.captureMaxEdgePx) }
        ),
        ConfigKey(
            name: "CAPTURE_SOURCE",
            section: .capture,
            kind: .choice(CaptureSourceMode.allCases.map(\.rawValue)),
            default: "both",
            help: "What one tick collects. Needs the Accessibility grant for anything but `screenshot`.",
            docs: """
                What one tick collects. Needs the Accessibility grant for anything but `screenshot`.
                  auto          - read the focused window's text, and screenshot only what it did not cover
                  accessibility - text only; a window that exposes nothing is recorded and left undescribed
                  screenshot    - pixels only, no accessibility read at all
                  both          - text and a screenshot every tick
                Ships as `both`. A text-versus-image comparison (2026-09-09, docs/decisions.md "Accessibility
                first") did not clear the bar set for `auto`: text-only describes matched image-only on 96% of
                task labels against a 100% image-vs-image ceiling, and were judged less faithful.
                """,
            apply: { c, v, _ in c.captureSource = try Config.enumValue("CAPTURE_SOURCE", v, default: c.captureSource) },
            read: { $0.captureSource.rawValue }
        ),
        ConfigKey(
            name: "CAPTURE_ON_BATTERY",
            section: .capture,
            kind: .choice(BatteryCaptureMode.allCases.map(\.rawValue)),
            default: "slow",
            help: "What to do on battery or in Low Power Mode.",
            docs: """
                What to do while the Mac is on battery, or while Low Power Mode is on: the second
                counts even on the charger, because it is you asking for less of everything.
                  normal         - battery changes nothing
                  slow           - capture at \(PowerPolicy.batteryIntervalMultiplier)x the interval, keep describing
                  describe-later - slow, and hold the describe queue until the charger is back
                Ships as `slow`: the 60 s default becomes 5 minutes unplugged, and the menu says so
                so the slower cadence is never mistaken for a fault. Frames held by `describe-later`
                stay `pending` and are described when mains comes back: nothing is dropped.
                """,
            apply: { c, v, _ in
                c.captureOnBattery = try Config.enumValue("CAPTURE_ON_BATTERY", v, default: c.captureOnBattery)
            },
            read: { $0.captureOnBattery.rawValue }
        ),
    ]
}

// MARK: - Privacy

private extension Config {
    static let privacyKeys: [ConfigKey] = [
        ConfigKey(
            name: "DELETE_SCREENSHOTS_AFTER_DESCRIBE",
            section: .privacy,
            kind: .bool,
            default: "false",
            help: "Delete a screenshot once it has been described.",
            apply: { c, v, _ in
                c.deleteScreenshotsAfterDescribe = try Config.bool(
                    "DELETE_SCREENSHOTS_AFTER_DESCRIBE", v, default: c.deleteScreenshotsAfterDescribe
                )
            },
            read: { String($0.deleteScreenshotsAfterDescribe) }
        ),
        ConfigKey(
            name: "DELETE_SENSITIVE_SCREENSHOTS",
            section: .privacy,
            kind: .bool,
            default: "true",
            help: "Always delete screenshots the describer flagged as sensitive.",
            apply: { c, v, _ in
                c.deleteSensitiveScreenshots = try Config.bool(
                    "DELETE_SENSITIVE_SCREENSHOTS", v, default: c.deleteSensitiveScreenshots
                )
            },
            read: { String($0.deleteSensitiveScreenshots) }
        ),
        ConfigKey(
            name: "RETENTION_DAYS",
            section: .privacy,
            kind: .int,
            default: "0",
            help: "Delete screenshots, descriptions and sessions older than this many days (0 keeps everything).",
            docs: """
                Delete screenshots, descriptions, window outlines and foreground sessions older than this many
                days. Counting includes today, so 30 keeps this month and drops the rest; 0, the default, keeps
                everything and is what Worklens did before this key existed. The quarter-hourly housekeeping
                pass does the deleting, and like the screenshot disk budget it never touches today or
                yesterday, whatever the number says. Timelines, the calendar and Granola events and
                the spend ledger survive a pass: see RETENTION_KEEP_REPORTS.
                """,
            minimum: 0,
            apply: { c, v, _ in
                c.retentionDays = try Config.int("RETENTION_DAYS", v, default: c.retentionDays)
            },
            read: { String($0.retentionDays) }
        ),
        ConfigKey(
            name: "RETENTION_KEEP_REPORTS",
            section: .privacy,
            kind: .bool,
            default: "true",
            help: "Keep the timelines for the days RETENTION_DAYS ages out.",
            docs: """
                Keep the timelines for the days RETENTION_DAYS ages out. They are the summaries the
                screenshots were taken for, so they stay by default even once the frames behind them are gone.
                Set it false and a retention pass also removes those days' activity blocks, and any
                friction rows or timeline files an older version wrote for them. Reports written before they
                were cut are never removed.
                Ignored when RETENTION_DAYS is 0.
                """,
            apply: { c, v, _ in
                c.retentionKeepReports = try Config.bool(
                    "RETENTION_KEEP_REPORTS", v, default: c.retentionKeepReports
                )
            },
            read: { String($0.retentionKeepReports) }
        ),
        ConfigKey(
            name: "COLLECT_BROWSER_URL",
            section: .privacy,
            kind: .bool,
            default: "true",
            help: "Read the frontmost browser tab URL (requires Automation permission).",
            apply: { c, v, _ in
                c.collectBrowserURL = try Config.bool("COLLECT_BROWSER_URL", v, default: c.collectBrowserURL)
            },
            read: { String($0.collectBrowserURL) }
        ),
        ConfigKey(
            name: "BLOCKED_BUNDLE_IDS",
            section: .privacy,
            kind: .list(","),
            default: "com.1password.1password,com.apple.keychainaccess",
            help: "Never capture while one of these apps is frontmost. Bundle ids, separated by , or ;.",
            docs: """
                Never capture while one of these apps is frontmost. Bundle ids, separated by commas or
                semicolons: either works, since no bundle id can contain one.
                Settings → Privacy and the menu’s “Never capture …” add to and take
                away from this list without touching this file: what they change is recorded in
                `~/Library/Application Support/Worklens/blocklists.json`, and this line stays the
                layer underneath it (#128).
                """,
            apply: { c, v, _ in c.blockedBundleIDs = Config.list(v, separators: [",", ";"]) ?? c.blockedBundleIDs },
            read: { $0.blockedBundleIDs.joined(separator: ",") }
        ),
        ConfigKey(
            name: "BLOCKED_TITLE_PATTERNS",
            section: .privacy,
            kind: .regexList(";"),
            default: "Private Browsing;Incognito;1Password;Password",
            help: "Never capture when the window title matches one of these regexes. Semicolon-separated.",
            docs: """
                Never capture when the window title matches one of these regexes. Case-insensitive,
                tested against the window title *and* the address. Semicolon-separated, and
                semicolons only: a comma is legal inside a quantifier such as `{2,3}`, so splitting on one
                would break the pattern. A value with a comma and no semicolon gets a warning at load.
                Editable from Settings → Privacy, which records what you changed
                in `~/Library/Application Support/Worklens/blocklists.json` rather than here (#128).
                """,
            apply: { c, v, _ in c.blockedTitlePatterns = Config.list(v, separator: ";") ?? c.blockedTitlePatterns },
            read: { $0.blockedTitlePatterns.joined(separator: ";") }
        ),
        ConfigKey(
            name: "BLOCKED_URL_HOSTS",
            section: .privacy,
            kind: .list(";"),
            default: "",
            help: "Never capture while the frontmost browser tab is on one of these hosts. Semicolon-separated.",
            docs: """
                Never capture while the frontmost browser tab is on one of these hosts. Suffix match at a dot
                boundary, so `nubank.com.br` also covers `app.nubank.com.br` (and not `notnubank.com.br`).
                Separated by semicolons or commas: either works, since no hostname can contain one. Empty
                by default: which banks and clinics you use is yours to name.
                Editable from Settings → Privacy and from the menu while the site is in front of you; those
                write `~/Library/Application Support/Worklens/blocklists.json` and leave this file alone (#128).
                """,
            apply: { c, v, _ in c.blockedURLHosts = Config.list(v, separators: [";", ","]) ?? c.blockedURLHosts },
            read: { $0.blockedURLHosts.joined(separator: ";") }
        ),
        ConfigKey(
            name: "REDACT_EXTRA_PATTERNS",
            section: .privacy,
            kind: .regexList(";"),
            default: "",
            help: "Extra regexes for the redactor that runs over the window title and URL before they are sent "
                + "to a model.",
            docs: """
                Extra regexes for the redactor that runs over the window title and URL before they are sent
                to a model. Each hit becomes [CUSTOM_n]. Semicolon-separated, case-insensitive; a pattern that
                does not compile is ignored with a warning, the rest still run. The built-ins already cover card
                numbers (Luhn-checked), IBANs, one-time codes, API keys and password=/senha= pairs; names,
                phone numbers, emails, CPFs, CNPJs, IPs and addresses are deliberately kept. Semicolons
                only, a comma is legal inside a quantifier such as `{2,3}`, and a value with a comma and
                no semicolon gets a warning at load.
                """,
            apply: { c, v, _ in c.redactExtraPatterns = Config.list(v, separator: ";") ?? c.redactExtraPatterns },
            read: { $0.redactExtraPatterns.joined(separator: ";") }
        ),
        ConfigKey(
            name: "PAUSE_REMINDER_HOURS",
            section: .privacy,
            kind: .int,
            default: "4",
            help: "How often to remind you that capture is still paused, in hours. 0 turns the reminder off.",
            docs: """
                Pausing (⌥⇧P, or the menu) outlives a quit, a crash and an auto-update: Worklens comes back
                paused rather than capturing, and the automatic updater will not restart the app while you
                are paused. Because a pause can now last a day, Worklens reminds you this often, in hours,
                that it is still paused and recording nothing. 0 turns the reminder off.
                """,
            apply: { c, v, _ in
                c.pauseReminderHours = try Config.int("PAUSE_REMINDER_HOURS", v, default: c.pauseReminderHours)
            },
            read: { String($0.pauseReminderHours) }
        ),
    ]
}

// MARK: - Budgets and storage

private extension Config {
    static let budgetKeys: [ConfigKey] = [
        ConfigKey(
            name: "DAILY_BUDGET_USD",
            section: .budgets,
            kind: .double,
            default: "1.50",
            help: "Spend limit per day, USD. Past it, screenshots are saved but not summarized.",
            docs: """
                Spend limit per day, USD. A hard stop on describing frames: past this, frames are still
                captured but marked `skipped/budget` and never sent, and the menu-bar icon says so. The
                menu can raise the budget for today alone, which also puts that day's skipped frames back
                in the queue; tomorrow starts on this value again. A check you click, such as verifying a
                key, is free and always goes out. Zero is a legal value and means
                "describe nothing"; a negative one is refused, since it could only ever be a typo for the
                same thing.
                """,
            minimum: 0,
            apply: { c, v, _ in c.dailyBudgetUSD = try Config.double("DAILY_BUDGET_USD", v, default: c.dailyBudgetUSD) },
            read: { String($0.dailyBudgetUSD) }
        ),
        ConfigKey(
            name: "SCREENSHOT_DISK_BUDGET_GB",
            section: .budgets,
            kind: .double,
            default: "20",
            help: "Prune old screenshots once they exceed this many GB.",
            docs: """
                Prune old screenshots once they exceed this many GB. Whole day folders go, oldest first, and
                never today or yesterday; the rows and their descriptions stay, they just lose their pixels.
                """,
            apply: { c, v, _ in
                c.screenshotDiskBudgetGB = try Config.double(
                    "SCREENSHOT_DISK_BUDGET_GB", v, default: c.screenshotDiskBudgetGB
                )
            },
            read: { String($0.screenshotDiskBudgetGB) }
        ),
        ConfigKey(
            name: "DATA_DIR",
            section: .budgets,
            kind: .path,
            default: "./data",
            help: "Where the SQLite DB, screenshots, timelines and reports live.",
            docs: """
                Where the SQLite DB, screenshots, timelines and reports live. Unset, it is ./data beside a
                checkout and ~/Library/Application Support/Worklens/data for an installed app, whose working
                directory is `/`. ~ and relative paths work; a relative path in a file means "next to that
                file", and `make install-env` makes it absolute. Worklens never writes this key itself:
                pinning the data directory is what `WORKLENS_ENV_FILE` is for, and a settings file the app
                can rewrite must not be able to take that away (#34).
                Keep it on this Mac's own disk. Point it at iCloud Drive, Dropbox, Google Drive, OneDrive or a
                network share and Worklens refuses to capture: a file provider syncs the SQLite write-ahead log
                out from under an open database, and the lock that keeps two Worklenses off one history is a
                kernel lock this Mac cannot enforce on another one. Two Macs means two installs with two data
                directories; the histories do not merge.
                """,
            editableInApp: false,
            apply: { c, v, cwd in c.dataDir = Config.expandPath(v, cwd: cwd) },
            read: { $0.dataDir.path }
        ),
        ConfigKey(
            name: "ALLOW_NONLOCAL_DATA_DIR",
            section: .budgets,
            kind: .bool,
            default: "false",
            help: "Capture into a DATA_DIR that iCloud, Dropbox or a network share is syncing anyway.",
            docs: """
                Capture into a DATA_DIR that iCloud Drive, Dropbox, Google Drive, OneDrive or a network share is
                syncing anyway. Off, and Worklens refuses to capture there: reading, MCP and the CLI's
                query commands still work, so nothing you already have becomes unreachable. This is a safety
                catch rather than a tuning knob (#87 deleted the knobs): the failure it prevents is a healthy
                database being moved aside as corrupt and replaced by an empty one, which is not something to
                discover afterwards.
                """,
            apply: { c, v, _ in
                c.allowNonLocalDataDir = try Config.bool("ALLOW_NONLOCAL_DATA_DIR", v, default: c.allowNonLocalDataDir)
            },
            read: { String($0.allowNonLocalDataDir) }
        ),
        ConfigKey(
            name: "LOG_LEVEL",
            section: .budgets,
            kind: .choice(LogLevel.allCases.map(\.rawValue)),
            default: "info",
            help: "debug | info | warn | error. debug is the only level that may include window titles or URLs.",
            docs: """
                debug | info | warn | error. debug is the only level that may include window titles or URLs.
                Every line also goes to DATA_DIR/logs/worklens-YYYY-MM-DD.log; files older than 14 days are
                deleted at launch.
                """,
            apply: { c, v, _ in c.logLevel = try Config.enumValue("LOG_LEVEL", v, default: c.logLevel) },
            read: { $0.logLevel.rawValue }
        ),
    ]
}

// MARK: - Context sources

private extension Config {
    static let contextKeys: [ConfigKey] = [
        ConfigKey(
            name: "CONTEXT_SYNC_MINUTES",
            section: .context,
            kind: .int,
            default: "15",
            help: "How often Worklens pulls your meetings from Granola and Google Calendar, in minutes.",
            apply: { c, v, _ in
                c.contextSyncMinutes = try Config.int("CONTEXT_SYNC_MINUTES", v, default: c.contextSyncMinutes)
            },
            read: { String($0.contextSyncMinutes) }
        ),
        ConfigKey(
            name: "GRANOLA_API_KEY",
            section: .context,
            kind: .secret,
            default: "",
            help: "Granola personal API key (grn_...). Creating one needs a Granola Business plan.",
            apply: { c, v, _ in c.granolaAPIKey = v },
            read: { Config.mask($0.granolaAPIKey) }
        ),
        ConfigKey(
            name: "GOOGLE_CLIENT_ID",
            section: .context,
            kind: .secret,
            default: "",
            help: "OAuth client id for Google Calendar.",
            docs: """
                Google Cloud -> enable the Calendar API -> OAuth client of type "Desktop app".
                Then connect from Settings → Connections.
                """,
            apply: { c, v, _ in c.googleClientID = v },
            read: { Config.mask($0.googleClientID) }
        ),
        ConfigKey(
            name: "GOOGLE_CLIENT_SECRET",
            section: .context,
            kind: .secret,
            default: "",
            help: "OAuth client secret for Google Calendar.",
            docs: "",
            apply: { c, v, _ in c.googleClientSecret = v },
            read: { Config.mask($0.googleClientSecret) }
        ),
        ConfigKey(
            name: "GOOGLE_TOKEN_STORE",
            section: .context,
            kind: .choice(GoogleTokenStorage.allCases.map(\.rawValue)),
            default: "keychain",
            help: "keychain | file. Where the Google Calendar refresh token is kept.",
            docs: """
                keychain | file. Where the Google Calendar refresh token is kept.
                You are asked which one you want in Settings → Connections when you connect, and this
                key records that answer. A value here pins it: comment this line out and the radio
                group pre-selects the store an existing grant is already in, or else the one that
                works on the binary you are running. Nothing resolves it behind your back (#139).
                `keychain` is the login keychain, visible and revocable in Keychain Access, and the
                reason macOS asks for your login keychain password after a rebuild: an item is authorised
                per code *hash* unless the signature carries an Apple Developer Team ID, so every build is
                a new partition and no ACL the app writes can pre-authorise it (docs/contributing/signing.md,
                "The Keychain dialog after every rebuild"). Worklens has no Developer account, so no build
                of it carries a Team ID, which is why the radio group pre-selects `file` while this key
                is unset.
                `file` keeps it in DATA_DIR/google-token.json at mode 0600 instead: no dialog, ever, for any
                build or worktree, and the grant is exactly as exposed as this file, which already holds
                GOOGLE_CLIENT_SECRET in plain text.
                Switching stores does not move a grant, and only a disconnect revokes one at Google. The
                menu in Settings → Advanced does the whole dance in one click: it disconnects from the old
                store and connects again into the new one.
                """,
            apply: { c, v, _ in
                c.googleTokenStore = try Config.enumValue("GOOGLE_TOKEN_STORE", v, default: c.googleTokenStore)
            },
            read: { $0.googleTokenStore.rawValue }
        ),
        // #314
        ConfigKey(
            name: "GITHUB_SHIPPED",
            section: .context,
            kind: .bool,
            default: "true",
            help: "Keep a ledger of what you shipped on GitHub, read through the GitHub CLI (gh).",
            docs: """
                Keep a ledger of what you shipped on GitHub: your merged and closed PRs, the issues you
                opened or closed, and your reviews on others' PRs, with their titles and links. Read through
                the GitHub CLI's own login on every context sync; Worklens never sees the token. Without
                `gh`, or logged out, it is a status line and nothing else. false deletes the ledger and
                stops syncing it. See docs/user/integrations/github.md.
                """,
            apply: { c, v, _ in
                c.githubShipped = try Config.bool("GITHUB_SHIPPED", v, default: c.githubShipped)
            },
            read: { String($0.githubShipped) }
        ),
        // #317
        ConfigKey(
            name: "MEMO_REPOS",
            section: .context,
            kind: .list(","),
            default: "",
            help: "Repos (owner/name, comma-separated) whose merged PRs of yours are read for company memos.",
            docs: """
                Repos, as owner/name separated by commas, whose merged PRs of yours are read for company
                memos: a PR that adds corpus/companies/<company>/<memo>.md publishes that company's memo,
                one that changes it updates it, and each is a row in the shipped ledger under the company.
                A company the catalog does not know yet is added to it. Needs GITHUB_SHIPPED=true. Empty
                (the default) reads nothing and deletes the memo rows. See docs/user/integrations/github.md.
                """,
            apply: { c, v, _ in
                c.memoRepos = Config.list(v, separator: ",")?.map(MemoOutputs.repoName) ?? c.memoRepos
            },
            read: { $0.memoRepos.joined(separator: ",") }
        ),
        // #321
        ConfigKey(
            name: "AGENT_SESSIONS",
            section: .context,
            kind: .bool,
            default: "true",
            help: "Read Claude Code and Codex session metadata to tie your time to repos and PRs.",
            docs: """
                Read Claude Code and Codex session metadata from their own logs on every context sync:
                when each session ran, its folder, branch and linked PRs, and the instants you typed a
                prompt. Never a prompt's text, a command, a tool's output or a session title, and nothing
                is sent anywhere. false deletes what was read and stops reading. See
                docs/user/integrations/agents.md.
                """,
            apply: { c, v, _ in
                c.agentSessions = try Config.bool("AGENT_SESSIONS", v, default: c.agentSessions)
            },
            read: { String($0.agentSessions) }
        ),
    ]

    static let updateKeys: [ConfigKey] = [
        ConfigKey(
            name: "AUTO_UPDATE_ENABLED",
            section: .updates,
            kind: .bool,
            default: "false",
            help: "Poll origin/main and, when it moves, rebuild and relaunch Worklens. Off by default.",
            docs: """
                Poll origin/main and, when it moves, run the same pull -> build -> sign -> relaunch round
                trip as Settings → General → Updates' "Update and restart…". Only ever touches the
                checkout the running app was built from, and only when that checkout is clean, on main,
                and this Mac has the "Worklens Dev" signing certificate (`make dev-cert`): an ad-hoc
                signature would cost you Screen Recording and Accessibility.
                Worklens quits and comes back about a minute later; nothing is captured in between.
                Off by default, so a new commit on main never rebuilds your app until you ask: "Check
                now" and "Update and restart…" work either way.
                What leaves your Mac while this is on: one `git ls-remote origin refs/heads/main`
                every AUTO_UPDATE_POLL_MINUTES, asking GitHub what main points at. No screen
                content, no account, no identifier, and none of it at all from a bundle copied out
                of its checkout, which gets no updater. PRIVACY.md, "What leaves your machine".
                """,
            apply: { c, v, _ in
                c.autoUpdateEnabled = try Config.bool("AUTO_UPDATE_ENABLED", v, default: c.autoUpdateEnabled)
            },
            read: { String($0.autoUpdateEnabled) }
        ),
        ConfigKey(
            name: "AUTO_UPDATE_POLL_MINUTES",
            section: .updates,
            kind: .int,
            default: "15",
            help: "How often to ask the remote what main points at. Minimum 5.",
            minimum: 5,
            apply: { c, v, _ in
                c.autoUpdatePollMinutes = try Config.int("AUTO_UPDATE_POLL_MINUTES", v, default: c.autoUpdatePollMinutes)
            },
            read: { String($0.autoUpdatePollMinutes) }
        ),
    ]
}

// MARK: - Retired (#87)

private extension Config {
    /// Keys that were `.env` settings once and are not any more. Kept so a stale `.env` gets one
    /// warning naming them rather than silent no-ops — and, since #126, rather than an
    /// `unknownKey` error that stops the app launching. Most moved next to their use (#87:
    /// `AXWalkLimits`, `GeminiClient`, `ImagePipeline`, `ForegroundContextCollector`, and the
    /// client that names itself in `llm_calls.provider`); `SLACK_USER_TOKEN` went with the Slack
    /// source (#285); a copy Worklens saved in settings.json stays there, read as retired. The Anthropic
    /// key and the four report keys went with the reports on 2026-10-05 (#298).
    static let retiredEntries: [ConfigKey] = [
        .retired("DESCRIBE_PROVIDER"),
        .retired("DESCRIBE_MEDIA_RESOLUTION"),
        .retired("DESCRIBE_THINKING_LEVEL"),
        .retired("REPORT_PROVIDER"),
        .retired("CAPTURE_JPEG_QUALITY"),
        .retired("URL_STORE_QUERY"),
        .retired("AX_MAX_NODES"),
        .retired("AX_MAX_DEPTH"),
        .retired("AX_WALK_TIMEOUT_MS"),
        .retired("AX_MAX_TEXT_CHARS"),
        .retired("AX_MIN_TEXT_CHARS"),
        .retired("GRANOLA_MODE"),
        .retired("SLACK_USER_TOKEN"),
        .retired("ANTHROPIC_API_KEY"),
        .retired("REPORT_MODEL"),
        .retired("REPORT_EFFORT"),
        .retired("REPORT_TIME"),
        .retired("REPORT_WEEKLY_DAY"),
    ]
}
