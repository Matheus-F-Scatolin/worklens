import Foundation
import GRDB

/// Versioned schema. Never edit a migration that has shipped — add the next one.
public enum Migrations {
    /// Every table in the current schema, in creation order.
    public static let tableNames = [
        "captures", "descriptions", "activity_blocks",
        "reports", "llm_calls", "context_events", "app_state",
        "foreground_sessions", "ax_snapshots", "friction_items",
        "search_fts", "search_docs", "coverage_events",
        "outputs",
        "agent_sessions", "agent_prompts", "agent_turns", "agent_session_prs", "agent_source_files",
        "project_assignments",
    ]

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE captures (
                  id TEXT PRIMARY KEY,
                  captured_at DATETIME NOT NULL,
                  display_id INTEGER,
                  image_path TEXT,
                  width INTEGER, height INTEGER,
                  dhash TEXT,
                  change_score REAL,
                  app_bundle_id TEXT, app_name TEXT, window_title TEXT, browser_url TEXT, url_host TEXT,
                  context_signature TEXT,
                  is_idle INTEGER NOT NULL DEFAULT 0,
                  is_redacted INTEGER NOT NULL DEFAULT 0,
                  is_meeting INTEGER NOT NULL DEFAULT 0,
                  skip_reason TEXT,
                  describe_status TEXT NOT NULL DEFAULT 'pending',
                  describe_attempts INTEGER NOT NULL DEFAULT 0,
                  created_at DATETIME NOT NULL
                );
                CREATE INDEX idx_captures_captured_at ON captures(captured_at);
                CREATE INDEX idx_captures_status ON captures(describe_status, captured_at);

                CREATE TABLE descriptions (
                  id TEXT PRIMARY KEY,
                  capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
                  provider TEXT NOT NULL, model TEXT NOT NULL,
                  app_key TEXT NOT NULL, task_key TEXT NOT NULL,
                  proposed_task TEXT,
                  summary_md TEXT NOT NULL,
                  details_json TEXT,
                  is_meeting INTEGER NOT NULL DEFAULT 0,
                  is_sensitive INTEGER NOT NULL DEFAULT 0,
                  confidence REAL,
                  is_inherited INTEGER NOT NULL DEFAULT 0,
                  prompt_tokens INTEGER, output_tokens INTEGER, thought_tokens INTEGER,
                  cost_usd REAL, latency_ms INTEGER,
                  raw_json TEXT,
                  created_at DATETIME NOT NULL
                );
                CREATE UNIQUE INDEX idx_descriptions_capture ON descriptions(capture_id);

                CREATE TABLE activity_blocks (
                  id TEXT PRIMARY KEY,
                  day TEXT NOT NULL,
                  start_at DATETIME NOT NULL, end_at DATETIME NOT NULL,
                  app_key TEXT NOT NULL, task_key TEXT NOT NULL,
                  title TEXT,
                  summary_md TEXT,
                  capture_count INTEGER NOT NULL DEFAULT 0,
                  source TEXT NOT NULL DEFAULT 'screen',
                  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL
                );
                CREATE INDEX idx_blocks_day ON activity_blocks(day, start_at);

                CREATE TABLE task_proposals (
                  id TEXT PRIMARY KEY,
                  app_key TEXT NOT NULL, proposed_task TEXT NOT NULL,
                  example_capture_id TEXT, example_summary TEXT,
                  count INTEGER NOT NULL DEFAULT 1,
                  status TEXT NOT NULL DEFAULT 'pending',
                  first_seen_at DATETIME NOT NULL, last_seen_at DATETIME NOT NULL
                );
                CREATE UNIQUE INDEX idx_proposals_key ON task_proposals(app_key, proposed_task);

                CREATE TABLE reports (
                  id TEXT PRIMARY KEY,
                  kind TEXT NOT NULL,
                  period_start TEXT NOT NULL, period_end TEXT NOT NULL,
                  provider TEXT NOT NULL, model TEXT NOT NULL,
                  content_md TEXT NOT NULL, stats_json TEXT,
                  file_path TEXT,
                  prompt_tokens INTEGER, output_tokens INTEGER, cost_usd REAL,
                  created_at DATETIME NOT NULL
                );
                CREATE INDEX idx_reports_period ON reports(kind, period_start);

                CREATE TABLE llm_calls (
                  id TEXT PRIMARY KEY,
                  provider TEXT NOT NULL, model TEXT NOT NULL,
                  purpose TEXT NOT NULL,
                  prompt_tokens INTEGER, output_tokens INTEGER, thought_tokens INTEGER, cached_tokens INTEGER,
                  cost_usd REAL NOT NULL DEFAULT 0,
                  latency_ms INTEGER, http_status INTEGER, error TEXT,
                  created_at DATETIME NOT NULL
                );
                CREATE INDEX idx_llm_calls_created ON llm_calls(created_at);

                CREATE TABLE context_events (
                  id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  external_id TEXT NOT NULL,
                  start_at DATETIME NOT NULL, end_at DATETIME,
                  title TEXT, participants_json TEXT, body_md TEXT, body_path TEXT,
                  is_meeting INTEGER NOT NULL DEFAULT 0,
                  raw_json TEXT,
                  synced_at DATETIME NOT NULL
                );
                CREATE UNIQUE INDEX idx_ctx_source_ext ON context_events(source, external_id);
                CREATE INDEX idx_ctx_start ON context_events(start_at);

                CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at DATETIME NOT NULL);
                """)
        }

        // #17: which price table a row's `cost_usd` was computed with, so a price change is
        // auditable instead of silently rewriting what yesterday cost. Nullable, because every
        // row written before this migration was priced by whatever shipped at the time.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE llm_calls ADD COLUMN pricing_version TEXT")
        }

        // #46: exact foreground intervals from `NSWorkspace.didActivateApplicationNotification`,
        // so per-app time stops being a function of the capture interval. `end_at` is null while
        // the interval is open (one row at a time); a blocked app keeps its interval and loses
        // its name. `source` exists so #47 can add imported rows without another migration.
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE foreground_sessions (
                  id TEXT PRIMARY KEY,
                  start_at DATETIME NOT NULL,
                  end_at DATETIME,
                  app_bundle_id TEXT, app_name TEXT,
                  is_blocked INTEGER NOT NULL DEFAULT 0,
                  source TEXT NOT NULL DEFAULT 'nsworkspace',
                  created_at DATETIME NOT NULL
                );
                CREATE INDEX idx_foreground_sessions_start ON foreground_sessions(start_at);
                """)
        }

        // #53: what the focused window exposed to assistive technology, one row per capture that
        // was walked. `text` is the redacted outline and is the only column retention removes —
        // `text_hash`, the counts and the coverage stay, so the describe decision and the
        // coverage numbers still work on a frame whose text has been dropped. `capture_source`
        // is nullable because every row written before this migration was pixels only, and it is
        // a plain string for the same reason `foreground_sessions.source` is: #54 adds
        // `accessibility` to it without another migration.
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
                ALTER TABLE captures ADD COLUMN capture_source TEXT;

                CREATE TABLE ax_snapshots (
                  capture_id TEXT PRIMARY KEY REFERENCES captures(id) ON DELETE CASCADE,
                  coverage TEXT NOT NULL,
                  node_count INTEGER NOT NULL DEFAULT 0,
                  text_chars INTEGER NOT NULL DEFAULT 0,
                  elapsed_ms INTEGER NOT NULL DEFAULT 0,
                  text_hash TEXT NOT NULL,
                  document_url TEXT,
                  text TEXT,
                  redactions_json TEXT,
                  created_at DATETIME NOT NULL
                );
                CREATE INDEX idx_ax_snapshots_created ON ax_snapshots(created_at);
                """)
        }

        // #55: which reader supplied a frame's window title and browser URL — `ax`,
        // `windowList`, `applescript` or `none`. Nullable, because rows written before this
        // migration cannot say, and because a skip or a blocked row carries neither field. Plain
        // strings for the reason `capture_source` is one: the point of storing them is a week of
        // numbers deciding whether the AppleScript probe can go, and a later issue removing a
        // source must not need a migration to stop writing it.
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                ALTER TABLE captures ADD COLUMN title_source TEXT;
                ALTER TABLE captures ADD COLUMN url_source TEXT;
                """)
        }

        // #86: the taxonomy learning loop is gone. Two days of it produced 28 proposals, all
        // pending and nearly all synonyms of keys that already existed, and the weekly Opus
        // review it fed never ran. `task_proposals` and `descriptions.proposed_task` have no
        // reader left. `DROP COLUMN` needs SQLite 3.35, which macOS 14+ ships; nothing indexes
        // the column, so the drop is a straight rewrite.
        migrator.registerMigration("drop-task-proposals") { db in
            try db.execute(sql: """
                DROP TABLE IF EXISTS task_proposals;
                ALTER TABLE descriptions DROP COLUMN proposed_task;
                """)
        }

        // #92: the friction ledger. The daily report ends in a fenced JSON block naming the
        // frictions it spotted; each becomes a row here, so recurrence across days — not one
        // day's impression — decides what the weekly report may call worth automating. `slug` is
        // the identity across days and is the only thing that must line up; `kind` is a plain
        // string for the reason `foreground_sessions.source` is one, so a later issue can change
        // the vocabulary without a migration. `report_id` is nullable and `SET NULL` on delete:
        // the ledger outlives the report it was parsed out of.
        migrator.registerMigration("friction-items") { db in
            try db.execute(sql: """
                CREATE TABLE friction_items (
                  id TEXT PRIMARY KEY,
                  day TEXT NOT NULL,
                  report_id TEXT REFERENCES reports(id) ON DELETE SET NULL,
                  slug TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  title TEXT NOT NULL,
                  minutes INTEGER,
                  evidence_json TEXT,
                  project TEXT,
                  created_at DATETIME NOT NULL
                );
                CREATE INDEX idx_friction_items_day ON friction_items(day, slug);
                CREATE INDEX idx_friction_items_slug ON friction_items(slug);
                """)
        }

        // #88: full-text search over the text already on disk — window outlines, descriptions,
        // window titles and URLs — so "where did I see that" has an answer that costs no model
        // call. One `search_fts` row per (capture, kind); the stores that own each text keep it up
        // to date, `SearchIndex` says how. `search_docs` maps (capture, kind) to the FTS rowid,
        // because FTS5 cannot index its own UNINDEXED columns and deleting by `capture_id` would
        // otherwise scan every document on a path that runs once per described frame.
        migrator.registerMigration("search-fts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
                  text,
                  capture_id UNINDEXED,
                  day UNINDEXED,
                  kind UNINDEXED,
                  tokenize='unicode61 remove_diacritics 2'
                );

                CREATE TABLE IF NOT EXISTS search_docs (
                  capture_id TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  doc_id INTEGER NOT NULL,
                  PRIMARY KEY (capture_id, kind)
                );
                """)
            try SearchIndex.backfill(db)
        }

        // #146: when Worklens was watching at all. `captures` answers "what was on screen"; it
        // cannot answer "was anything looking", and an afternoon you paused looks exactly like an
        // afternoon you spent away from the machine. One row per transition — started, paused,
        // resumed, stopped — and nothing about what was on screen, which is the promise
        // PRIVACY.md already made for a pause. `kind` and `reason` are plain strings for the
        // reason `foreground_sessions.source` is one.
        migrator.registerMigration("coverage-events") { db in
            try db.execute(sql: """
                CREATE TABLE coverage_events (
                  id TEXT PRIMARY KEY,
                  at DATETIME NOT NULL,
                  kind TEXT NOT NULL,
                  reason TEXT
                );
                CREATE INDEX idx_coverage_events_at ON coverage_events(at);
                """)
        }

        // #245: who found a friction row. The daily report was the only writer until a detector
        // started measuring re-entry, repeated sequences and waiting off the day's own blocks,
        // and the two must not overwrite each other, so replacing a day's rows was per-source.
        // Additive with a default, so every row written before today keeps the provenance it had
        // and an older build still reads the table.
        //
        // #299 removed the ledger that wrote these rows. The table stays, with no migration that
        // drops it: an older build still reads it, and `DataEraser` and `Retention` delete its
        // rows by plain SQL.
        migrator.registerMigration("friction-source") { db in
            try db.execute(sql: """
                ALTER TABLE friction_items ADD COLUMN source TEXT NOT NULL DEFAULT 'report';
                CREATE INDEX idx_friction_items_day_source ON friction_items(day, source);
                """)
        }

        // #249: the day's sentence. `content_md` already holds the report's opening line, but
        // reading it back means loading every report to fill a sidebar, so the sentence is
        // lifted out once, when the report is written. Additive and nullable: every row written
        // before today keeps NULL and falls back to the sentence the day's own stats make, and
        // an older build still opens the database.
        migrator.registerMigration("day-headline") { db in
            try db.execute(sql: "ALTER TABLE reports ADD COLUMN headline TEXT")
        }

        // The interval the scheduler was on when it took the frame — the configured one, stretched
        // on battery (#145) and inside a meeting (#66). Without it the timeline joined a day of
        // five-minute battery frames with the one-minute tolerance and drew each as its own
        // minute. Nil on every row written before it, which keeps the old rule for them.
        migrator.registerMigration("capture-interval") { db in
            try db.execute(sql: "ALTER TABLE captures ADD COLUMN interval_seconds INTEGER")
        }

        // #311: `ax_snapshots.document_url` kept a Chromium tab's query string and fragment, which
        // `browser_url` has always dropped (#87). Rewrites the stored values through the same
        // rule; no DDL, so an older build still opens the database.
        migrator.registerMigration("ledger-document-url-strip-ax-snapshots") { db in
            try AXSnapshotStore.normalizeDocumentURLs(db)
        }

        // #314: the shipped ledger. `kind` is a string so a kind a later build adds never breaks
        // this one; `project_key` and `project_rule` stay NULL until #319/#321 attribute rows.
        migrator.registerMigration("ledger-314-outputs") { db in
            try db.execute(sql: """
                CREATE TABLE outputs (
                  id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  at DATETIME NOT NULL,
                  repo TEXT,
                  number INTEGER,
                  url TEXT,
                  title TEXT,
                  path TEXT,
                  resource_key TEXT,
                  external_id TEXT NOT NULL,
                  project_key TEXT,
                  project_rule TEXT,
                  provenance TEXT NOT NULL,
                  synced_at DATETIME NOT NULL
                );
                CREATE UNIQUE INDEX idx_outputs_source_ext ON outputs(source, external_id);
                CREATE INDEX idx_outputs_at ON outputs(at);
                CREATE INDEX idx_outputs_repo_number ON outputs(repo, number);
                CREATE INDEX idx_outputs_resource_key ON outputs(resource_key);
                """)
        }

        // #316: a Granola meeting's next steps and decisions, parsed from the full summary at
        // sync time. Nullable: a NULL row is what `refreshMeetingOutcomes` fills on the next sync.
        migrator.registerMigration("ledger-granola-next-steps-outcomes") { db in
            try db.execute(sql: "ALTER TABLE context_events ADD COLUMN outcomes_json TEXT")
        }

        // #332: the outline kept a scheme-less address's query (a Chromium omnibox shows no
        // `https://`). Rewrites the stored outlines and their `ax` search rows through the
        // redactor's rule; no DDL, so an older build still opens the database.
        migrator.registerMigration("ledger-outline-url-strip-ax-text") { db in
            try AXOutlineRepair.stripURLQueries(db)
        }

        // #321: Claude Code and Codex session metadata. Never a prompt's text, a command, a tool's
        // output or a session title: ids, instants, the working folder, the branch and PR links.
        // `tool`, `host` and `repo_rule` are plain strings so a later parser never breaks this one.
        migrator.registerMigration("ledger-agent-sessions-v1") { db in
            try db.execute(sql: """
                CREATE TABLE agent_sessions (
                  id TEXT PRIMARY KEY,
                  tool TEXT NOT NULL,
                  host TEXT,
                  parent_id TEXT,
                  start_at DATETIME,
                  end_at DATETIME,
                  cwd TEXT,
                  vcs_repo TEXT,
                  repo TEXT,
                  repo_rule TEXT,
                  branch TEXT,
                  edited INTEGER NOT NULL DEFAULT 0,
                  parser INTEGER NOT NULL
                );
                CREATE INDEX idx_agent_sessions_span ON agent_sessions(start_at, end_at);

                CREATE TABLE agent_prompts (
                  record_id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  at DATETIME NOT NULL
                );
                CREATE INDEX idx_agent_prompts_at ON agent_prompts(at);

                CREATE TABLE agent_turns (
                  session_id TEXT NOT NULL,
                  start_at DATETIME NOT NULL,
                  end_at DATETIME NOT NULL,
                  PRIMARY KEY (session_id, start_at)
                );
                CREATE INDEX idx_agent_turns_span ON agent_turns(start_at, end_at);

                CREATE TABLE agent_session_prs (
                  session_id TEXT NOT NULL,
                  pr_key TEXT NOT NULL,
                  state TEXT,
                  PRIMARY KEY (session_id, pr_key)
                );
                CREATE INDEX idx_agent_session_prs_key ON agent_session_prs(pr_key);

                CREATE TABLE agent_source_files (
                  path TEXT PRIMARY KEY,
                  store TEXT NOT NULL,
                  session_id TEXT,
                  size INTEGER NOT NULL,
                  mtime DATETIME NOT NULL,
                  offset INTEGER NOT NULL,
                  open_turn_at DATETIME,
                  parser INTEGER NOT NULL,
                  edited INTEGER NOT NULL DEFAULT 0
                );
                """)
        }

        // #324: a stretch of time you said was one project. Read by the project spans on top of
        // everything else; kept by retention and the date-range delete, like `context_events`.
        migrator.registerMigration("ledger-324-project-assignments") { db in
            try db.execute(sql: """
                CREATE TABLE project_assignments (
                  id INTEGER PRIMARY KEY,
                  from_at DATETIME NOT NULL,
                  to_at DATETIME NOT NULL,
                  project_key TEXT NOT NULL,
                  created_at DATETIME NOT NULL
                );
                CREATE INDEX idx_project_assignments_range ON project_assignments(from_at, to_at);
                """)
        }

        return migrator
    }
}
