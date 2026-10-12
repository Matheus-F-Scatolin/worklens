import Foundation

/// The taxonomy Worklens ships with, embedded as a string rather than as an SPM resource
/// (`Bundle.module` is unreliable inside a hand-assembled .app — see CLAUDE.md).
///
/// On first run `TaxonomyStore` writes this text verbatim to `DATA_DIR/taxonomy.json`, so the
/// file on disk is byte-identical to what is compiled in. After that the file is the source of
/// truth: the user may edit it freely and the store picks the change up within 30 s.
public enum TaxonomySeed {
    public static let json: String = #"""
{
  "version": 1,
  "apps": [
    {
      "key": "slack", "name": "Slack", "category": "communication",
      "bundle_ids": ["com.tinyspeck.slackmacgap"],
      "tasks": [
        {"key": "reading_messages", "description": "Reading channels or DMs"},
        {"key": "writing_messages", "description": "Composing or replying"},
        {"key": "searching", "description": "Searching Slack history"},
        {"key": "huddle", "description": "In a Slack huddle / call"}
      ]
    },
    {
      "key": "browser", "name": "Web browser", "category": "browser",
      "bundle_ids": ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox"],
      "tasks": [
        {"key": "reading", "description": "Reading an article, doc or page"},
        {"key": "researching", "description": "Searching and comparing multiple sources"},
        {"key": "forms_admin", "description": "Filling forms, settings, admin portals"},
        {"key": "video", "description": "Watching video"},
        {"key": "social", "description": "Social media feeds"}
      ],
      "web_apps": [
        {"key": "gmail", "name": "Gmail", "url_patterns": ["mail.google.com"], "category": "communication",
         "tasks": [{"key": "reading_email", "description": ""}, {"key": "writing_email", "description": ""}, {"key": "triaging", "description": "Archiving, labeling, searching"}]},
        {"key": "gcal", "name": "Google Calendar", "url_patterns": ["calendar.google.com"], "category": "planning",
         "tasks": [{"key": "scheduling", "description": ""}, {"key": "reviewing_schedule", "description": ""}]},
        {"key": "gdocs", "name": "Google Docs", "url_patterns": ["docs.google.com/document"], "category": "writing",
         "tasks": [{"key": "writing", "description": ""}, {"key": "reviewing", "description": "Reading / commenting"}]},
        {"key": "gsheets", "name": "Google Sheets", "url_patterns": ["docs.google.com/spreadsheets"], "category": "analysis",
         "tasks": [{"key": "building_model", "description": ""}, {"key": "data_entry", "description": ""}, {"key": "analysis", "description": ""}]},
        {"key": "gslides", "name": "Google Slides", "url_patterns": ["docs.google.com/presentation"], "category": "writing", "tasks": [{"key": "building_deck", "description": ""}, {"key": "reviewing", "description": ""}]},
        {"key": "gdrive", "name": "Google Drive", "url_patterns": ["drive.google.com"], "category": "files", "tasks": [{"key": "browsing_files", "description": ""}]},
        {"key": "affinity", "name": "Affinity CRM", "url_patterns": ["affinity.co"], "category": "crm",
         "tasks": [{"key": "updating_pipeline", "description": "Editing deal status / fields"}, {"key": "reviewing_pipeline", "description": ""}, {"key": "logging_notes", "description": ""}]},
        {"key": "notion_web", "name": "Notion", "url_patterns": ["notion.so"], "category": "notes", "tasks": [{"key": "writing_notes", "description": ""}, {"key": "reading_notes", "description": ""}]},
        {"key": "github", "name": "GitHub", "url_patterns": ["github.com"], "category": "dev", "tasks": [{"key": "reviewing_pr", "description": ""}, {"key": "reading_code", "description": ""}, {"key": "issues", "description": "Reading / writing issues"}]},
        {"key": "linkedin", "name": "LinkedIn", "url_patterns": ["linkedin.com"], "category": "social", "tasks": [{"key": "feed", "description": ""}, {"key": "messaging", "description": ""}, {"key": "researching_people", "description": ""}]},
        {"key": "x", "name": "X / Twitter", "url_patterns": ["x.com", "twitter.com"], "category": "social", "tasks": [{"key": "feed", "description": ""}]},
        {"key": "youtube", "name": "YouTube", "url_patterns": ["youtube.com"], "category": "media", "tasks": [{"key": "watching", "description": ""}]},
        {"key": "gmeet", "name": "Google Meet", "url_patterns": ["meet.google.com"], "category": "meeting", "tasks": [{"key": "video_call", "description": ""}]},
        {"key": "zoom_web", "name": "Zoom (web)", "url_patterns": ["zoom.us"], "category": "meeting", "tasks": [{"key": "video_call", "description": ""}]},
        {"key": "granola_web", "name": "Granola (web)", "url_patterns": ["granola.ai"], "category": "notes", "tasks": [{"key": "reviewing_meeting_notes", "description": ""}]},
        {"key": "claude", "name": "Claude", "url_patterns": ["claude.ai"], "category": "ai", "tasks": [{"key": "chatting_with_ai", "description": ""}]},
        {"key": "chatgpt", "name": "ChatGPT", "url_patterns": ["chatgpt.com"], "category": "ai", "tasks": [{"key": "chatting_with_ai", "description": ""}]},
        {"key": "perplexity", "name": "Perplexity", "url_patterns": ["perplexity.ai"], "category": "ai", "tasks": [{"key": "researching", "description": ""}]}
      ]
    },
    {"key": "mail", "name": "Apple Mail", "category": "communication", "bundle_ids": ["com.apple.mail"], "tasks": [{"key": "reading_email", "description": ""}, {"key": "writing_email", "description": ""}, {"key": "triaging", "description": ""}]},
    {"key": "outlook", "name": "Outlook", "category": "communication", "bundle_ids": ["com.microsoft.Outlook"], "tasks": [{"key": "reading_email", "description": ""}, {"key": "writing_email", "description": ""}, {"key": "calendar", "description": ""}]},
    {"key": "calendar", "name": "Calendar", "category": "planning", "bundle_ids": ["com.apple.iCal"], "tasks": [{"key": "scheduling", "description": ""}, {"key": "reviewing_schedule", "description": ""}]},
    {"key": "zoom", "name": "Zoom", "category": "meeting", "bundle_ids": ["us.zoom.xos"], "tasks": [{"key": "video_call", "description": ""}]},
    {"key": "teams", "name": "Microsoft Teams", "category": "meeting", "bundle_ids": ["com.microsoft.teams2"], "tasks": [{"key": "video_call", "description": ""}, {"key": "messaging", "description": ""}]},
    {"key": "facetime", "name": "FaceTime", "category": "meeting", "bundle_ids": ["com.apple.FaceTime"], "tasks": [{"key": "video_call", "description": ""}]},
    {"key": "granola", "name": "Granola", "category": "notes", "bundle_ids": ["com.granola.app"], "tasks": [{"key": "in_meeting_notes", "description": "Live meeting with Granola open"}, {"key": "reviewing_meeting_notes", "description": ""}]},
    {"key": "notion", "name": "Notion", "category": "notes", "bundle_ids": ["notion.id"], "tasks": [{"key": "writing_notes", "description": ""}, {"key": "reading_notes", "description": ""}]},
    {"key": "obsidian", "name": "Obsidian", "category": "notes", "bundle_ids": ["md.obsidian"], "tasks": [{"key": "writing_notes", "description": ""}, {"key": "reading_notes", "description": ""}]},
    {"key": "apple_notes", "name": "Notes", "category": "notes", "bundle_ids": ["com.apple.Notes"], "tasks": [{"key": "writing_notes", "description": ""}]},
    {"key": "excel", "name": "Excel", "category": "analysis", "bundle_ids": ["com.microsoft.Excel"], "tasks": [{"key": "building_model", "description": ""}, {"key": "data_entry", "description": ""}, {"key": "analysis", "description": ""}]},
    {"key": "numbers", "name": "Numbers", "category": "analysis", "bundle_ids": ["com.apple.iWork.Numbers"], "tasks": [{"key": "building_model", "description": ""}, {"key": "analysis", "description": ""}]},
    {"key": "word", "name": "Word", "category": "writing", "bundle_ids": ["com.microsoft.Word"], "tasks": [{"key": "writing", "description": ""}, {"key": "reviewing", "description": ""}]},
    {"key": "pages", "name": "Pages", "category": "writing", "bundle_ids": ["com.apple.iWork.Pages"], "tasks": [{"key": "writing", "description": ""}]},
    {"key": "powerpoint", "name": "PowerPoint", "category": "writing", "bundle_ids": ["com.microsoft.Powerpoint"], "tasks": [{"key": "building_deck", "description": ""}, {"key": "reviewing", "description": ""}]},
    {"key": "keynote", "name": "Keynote", "category": "writing", "bundle_ids": ["com.apple.iWork.Keynote"], "tasks": [{"key": "building_deck", "description": ""}]},
    {"key": "preview", "name": "Preview", "category": "reading", "bundle_ids": ["com.apple.Preview"], "tasks": [{"key": "reading_pdf", "description": ""}, {"key": "annotating", "description": ""}]},
    {"key": "finder", "name": "Finder", "category": "files", "bundle_ids": ["com.apple.finder"], "tasks": [{"key": "browsing_files", "description": ""}, {"key": "organizing_files", "description": ""}]},
    {"key": "vscode", "name": "VS Code", "category": "dev", "bundle_ids": ["com.microsoft.VSCode"], "tasks": [{"key": "coding", "description": ""}, {"key": "debugging", "description": ""}, {"key": "reading_code", "description": ""}]},
    {"key": "cursor", "name": "Cursor", "category": "dev", "bundle_ids": ["com.todesktop.230313mzl4w4u92"], "tasks": [{"key": "coding", "description": ""}, {"key": "chatting_with_ai", "description": ""}]},
    {"key": "xcode", "name": "Xcode", "category": "dev", "bundle_ids": ["com.apple.dt.Xcode"], "tasks": [{"key": "coding", "description": ""}, {"key": "debugging", "description": ""}]},
    {"key": "terminal", "name": "Terminal", "category": "dev", "bundle_ids": ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "com.cmuxterm.app"], "tasks": [{"key": "running_commands", "description": ""}, {"key": "coding_with_agent", "description": "Working with an AI coding agent in the terminal"}]},
    {"key": "claude_desktop", "name": "Claude Desktop", "category": "ai", "bundle_ids": ["com.anthropic.claudefordesktop"], "tasks": [{"key": "chatting_with_ai", "description": ""}]},
    {"key": "chatgpt_desktop", "name": "ChatGPT Desktop", "category": "ai", "bundle_ids": ["com.openai.chat"], "tasks": [{"key": "chatting_with_ai", "description": ""}]},
    {"key": "codex_desktop", "name": "Codex", "category": "dev", "bundle_ids": ["com.openai.codex"], "tasks": [{"key": "coding_with_agent", "description": "Working with an AI coding agent"}, {"key": "reading_code", "description": ""}]},
    {"key": "figma", "name": "Figma", "category": "design", "bundle_ids": ["com.figma.Desktop"], "tasks": [{"key": "designing", "description": ""}, {"key": "reviewing", "description": ""}]},
    {"key": "messages", "name": "Messages", "category": "communication", "bundle_ids": ["com.apple.MobileSMS"], "tasks": [{"key": "messaging", "description": ""}]},
    {"key": "whatsapp", "name": "WhatsApp", "category": "communication", "bundle_ids": ["net.whatsapp.WhatsApp"], "tasks": [{"key": "messaging", "description": ""}]},
    {"key": "telegram", "name": "Telegram", "category": "communication", "bundle_ids": ["ru.keepcoder.Telegram"], "tasks": [{"key": "messaging", "description": ""}]},
    {"key": "spotify", "name": "Spotify", "category": "media", "bundle_ids": ["com.spotify.client"], "tasks": [{"key": "music", "description": ""}]},
    {"key": "system_settings", "name": "System Settings", "category": "admin", "bundle_ids": ["com.apple.systempreferences"], "tasks": [{"key": "configuring", "description": ""}]},
    {"key": "worklens", "name": "Worklens", "category": "reading", "bundle_ids": ["dev.worklens.app"], "tasks": [{"key": "reading_timeline", "description": "Reading your own timeline"}, {"key": "configuring", "description": ""}]}
  ],
  "projects": [],
  "universal_tasks": [
    {"key": "other", "description": "Does not fit any listed task"},
    {"key": "switching", "description": "Transitional: app switcher, launcher, empty desktop"}
  ]
}

"""#

    /// Bumped whenever a release adds apps an existing `taxonomy.json` should learn about. The
    /// seed above only reaches a fresh data directory; `AppLabelRepair` merges each revision's
    /// `additions` into an existing file once (#312).
    public static let appsRevision = 2

    /// The bundle ids each revision added to the seed, keyed by revision. An install whose
    /// recorded revision is lower gets them merged in by `TaxonomyMerge`, never removing or
    /// renaming anything already there.
    public static let additions: [Int: [String]] = [
        2: ["com.openai.codex", "com.cmuxterm.app", "dev.worklens.app"],
    ]

    /// The ids `additions` lists above `revision`, oldest revision first.
    public static func additions(after revision: Int) -> [String] {
        additions.keys.sorted().filter { $0 > revision }.flatMap { additions[$0] ?? [] }
    }
}
