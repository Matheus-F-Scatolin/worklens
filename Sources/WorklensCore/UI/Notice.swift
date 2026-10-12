import Foundation

/// What a notice is for. The kind is what decides how long it lives: #110 replaced the single
/// ten-minute slot that made every message — a missing API key and a delete confirmation alike —
/// disappear after ten minutes whether or not it was still true.
public enum NoticeKind: String, Codable, Sendable, Equatable {
    /// Something is wrong and still is. Stays until the user dismisses it, or — when a
    /// `SetupIssue` raised it — until the condition that raised it is gone.
    case problem
    /// Something the user asked for finished: a delete, a sweep. A minute is enough to read it.
    case done
    /// Worth saying once and not worth keeping: a quiet day, a folder opened instead of a file.
    case info
}

/// The one button a notice may carry. A plain string enum rather than a closure so a notice can
/// be persisted and re-rendered after a relaunch; the `Worklens` target maps each case onto the
/// method that performs it.
public enum NoticeAction: String, Codable, Sendable, Equatable, CaseIterable {
    case openEnvFile
    /// #124: Settings → Models & budget, on the Accounts section — where the two API keys are now
    /// typed. It replaced `openEnvFile` on the key issues: a text editor is no longer the only
    /// place a key can go, and it was never the friendliest one.
    case openAccountSettings
    case reloadConfig
    case grantScreenRecording
    case grantAccessibility
    /// #117: the first Screen Recording grant only reaches a process that starts after it, so
    /// a notice that says so carries the button that does it.
    case relaunchWorklens
    /// The two report retries. Nothing raises them since the reports were cut (2026-10-05); they
    /// stay so a stored notice log that holds one still decodes — an unknown raw value would
    /// drop the whole log — and `AppModel` filters them out on load.
    case retryDailyReport
    case retryWeeklyReport
    case syncIntegrations
    /// #139: the Google grant expired — Settings → Integrations, where the Reconnect button is.
    case reconnectGoogle
    /// #248: an assistant's entry no longer reaches this build — Settings → Claude, where the
    /// Reconnect button is.
    case reconnectClaude
    /// #156: the last run ended without shutting down, and the log for the day it stopped is the
    /// only place that says what it was doing.
    case openLogFile

    /// What the button says. Second person, like everything else the user reads.
    public var label: String {
        switch self {
        case .openEnvFile: return L10n.string("Open .env…")
        case .openAccountSettings: return L10n.string("Add your Gemini API key…")
        case .reloadConfig: return L10n.string("Reload configuration")
        case .grantScreenRecording: return ScreenRecordingCopy.askLabel
        case .grantAccessibility: return L10n.string("Grant Accessibility…")
        case .relaunchWorklens: return ScreenRecordingCopy.relaunchLabel
        case .retryDailyReport: return L10n.string("Write today's report")
        case .retryWeeklyReport: return L10n.string("Write this week's report")
        case .syncIntegrations: return L10n.string("Sync integrations now")
        case .reconnectGoogle: return L10n.string("Reconnect Google\u{2026}")
        case .reconnectClaude: return L10n.string("Reconnect Claude\u{2026}")
        case .openLogFile: return L10n.string("Open the log\u{2026}")
        }
    }
}

/// A condition that is wrong and stays wrong until something about the machine changes. Unlike an
/// ad-hoc problem it is not raised once and remembered: it is re-derived every time the services
/// are built, so it cannot outlive its cause and cannot be missed because nobody was awake.
///
/// Deliberately *not* here: an unreadable data directory, which still sets `MenuState.configError`
/// and degrades the whole menu (there is nothing to describe into, so a single line
/// would understate it); and the two advisory signals `accessibilityMissing` and
/// `browsersMissingURLs`, which are already condition-backed, already never expire, and stay
/// exactly as they are — capture works without them.
public enum SetupIssue: String, Codable, Sendable, CaseIterable, Equatable {
    /// Screen Recording is denied or was revoked: no pixels are being captured.
    case screenRecordingDenied
    /// `DATA_DIR` is in a folder a file provider syncs, or on a network volume: capture is
    /// refused rather than risking the database (`DataDirLocation`).
    case dataDirNotLocal
    /// This data directory was last written by a different Mac (`MachineName`).
    case dataDirAnotherMac
    /// A key is set but the provider rejected it (401/403).
    case keyRejected
    /// `GEMINI_API_KEY` is missing: frames pile up undescribed.
    case noGeminiKey
    /// The Claude key was missing when a report was asked for. Nothing raises it since the reports
    /// were cut (2026-10-05); it stays so a stored notice log that holds one still decodes, and
    /// `AppModel` drops it on load.
    case noAnthropicKey
    /// #139: Google expired the grant — every Testing consent screen's does, about weekly — so
    /// Calendar is paused until the user signs in again. Last in the severity order:
    /// nothing else stops, and it is one click away from fixed.
    case googleReconnect
    /// #248: a client that was connected to the read-only MCP server is not any more — the app
    /// moved, or was reinstalled, and the entry in that client's file points at a binary that is
    /// gone or at another build. Raised only on an install that once had a working link, so a
    /// user who never connected one is never told theirs broke. Last: nothing Worklens itself
    /// does has stopped.
    case mcpDisconnected

    /// Severity order, worst first — this is the order `allCases` declares, and the menu shows
    /// the first open one.
    public static var bySeverity: [SetupIssue] { allCases }

    public var message: String {
        switch self {
        case .screenRecordingDenied:
            // The wording that assumes a grant existed. `AppModel` raises this issue with
            // `ScreenRecordingCopy.problemMessage(everGranted:)` instead, which is the same
            // sentence on a Mac that has been granted once and a truer one on a Mac that has not.
            return ScreenRecordingCopy.problemMessage(everGranted: true)
        case .dataDirNotLocal:
            return L10n.string("DATA_DIR is in a synced folder: capture is off so the database is not risked.")
        case .dataDirAnotherMac:
            return L10n.string("This data directory was last written by a different Mac.")
        case .keyRejected:
            return L10n.string("The API key was rejected: check it under Settings → Connections.")
        case .noGeminiKey:
            return L10n.string(
                "GEMINI_API_KEY is not set: screenshots are saved but not summarized. docs/user/setup.md#keys says where to get one."
            )
        case .noAnthropicKey:
            // Never raised any more; only a notice stored before 2026-10-05 can hold it.
            return L10n.string("Reports are off: add a Claude key in Settings to turn them on.")
        case .googleReconnect:
            return L10n.string(
                "Your Google sign-in expired: Calendar is paused until you reconnect."
            )
        case .mcpDisconnected:
            // The fact, then the remedy, and no path in it: this sentence reaches the menu, the
            // Activity list and a notification, and a configuration path belongs in none of them.
            return L10n.string(
                "An assistant on this Mac can no longer reach Worklens: reconnect it in Settings → Connections."
            )
        }
    }

    public var action: NoticeAction? {
        switch self {
        case .screenRecordingDenied: return .grantScreenRecording
        // #124: a key now has a home in Settings, so the three key issues lead there rather than
        // into a text editor. `DATA_DIR` still has no control and still opens the file.
        case .keyRejected, .noGeminiKey, .noAnthropicKey: return .openAccountSettings
        case .dataDirNotLocal: return .openEnvFile
        case .googleReconnect: return .reconnectGoogle
        // #248: the button opens the Claude pane, whose own Reconnect repoints the entry with
        // its backup.
        case .mcpDisconnected: return .reconnectClaude
        case .dataDirAnotherMac: return nil
        }
    }

    /// True when the issue means a whole stage of the pipeline is doing nothing, which is what
    /// earns the menu-bar icon. `MenuModel` keeps the older rule for the two permission
    /// *advisories* — Accessibility and browser URLs never touch the icon, because capture keeps
    /// working without them and a permanent badge for a grant the user may never want is noise.
    /// A missing or rejected key is not that: nothing is described at all.
    ///
    /// #239 was the one exception: a missing *Claude* key turned reports off, which was a
    /// configuration somebody chose, so it never wore the icon.
    public var blocksWork: Bool {
        switch self {
        case .keyRejected, .noGeminiKey, .dataDirNotLocal: return true
        case .noAnthropicKey: return false  // legacy: never raised since 2026-10-05
        case .screenRecordingDenied: return false  // the scheduler's own state already says so
        // Nothing has stopped: the folder may simply have been copied here, or the Mac renamed.
        case .dataDirAnotherMac: return false
        // Capture and describing carry on; two context sources are paused.
        case .googleReconnect: return false
        // Everything Worklens does still happens; what stopped is an assistant's way in.
        case .mcpDisconnected: return false
        }
    }
}

/// One thing worth telling the user, with when it happened and what to do about it.
public struct Notice: Codable, Sendable, Equatable, Identifiable {
    /// How long a `.done` notice stays on the menu.
    public static let doneVisibility: TimeInterval = 60
    /// How long an `.info` notice stays. `MenuBarExtra(.menu)` gives no "the menu opened" hook —
    /// it hands out no `NSStatusItem` and the model is a pure struct
    /// recomputed from `now` — so "until the next menu open" has nothing to hang on and this
    /// keeps the old ten minutes instead.
    public static let infoVisibility: TimeInterval = 600

    public let id: UUID
    public let kind: NoticeKind
    public let message: String
    public let at: Date
    public let action: NoticeAction?
    /// Set when a `SetupIssue` raised this notice. Such a notice has no lifetime at all: it is
    /// removed when the condition clears, not when a timer runs out.
    public let issue: SetupIssue?
    /// When the user dismissed it, if they did.
    public var dismissedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: NoticeKind,
        message: String,
        at: Date = Date(),
        action: NoticeAction? = nil,
        issue: SetupIssue? = nil,
        dismissedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.at = at
        self.action = action
        self.issue = issue
        self.dismissedAt = dismissedAt
    }

    /// `message` overrides `issue.message` where the condition alone cannot say everything: the
    /// two true wordings of one condition (#117: Screen Recording never granted versus revoked),
    /// or a detail only the caller knows — which folder, which other Mac (#122). The issue is
    /// unchanged, so `raise`/`clear` still pair up and a persisted notice still knows what
    /// raised it.
    public init(_ issue: SetupIssue, message: String? = nil, at: Date = Date()) {
        self.init(
            id: UUID(), kind: .problem, message: message ?? issue.message, at: at,
            action: issue.action, issue: issue
        )
    }

    /// Whether the menu should still be showing this.
    public func isLive(at now: Date) -> Bool {
        guard dismissedAt == nil else { return false }
        switch kind {
        case .problem: return true
        case .done: return now.timeIntervalSince(at) < Notice.doneVisibility
        case .info: return now.timeIntervalSince(at) < Notice.infoVisibility
        }
    }

    /// Still true, as far as anyone knows: an open problem. What the Activity list marks.
    public var isOpen: Bool { kind == .problem && dismissedAt == nil }

    /// A notice that asks you to fix nothing, only to know: its one button opens the log (the
    /// run that ended without shutting down). Seeing it in Settings is reviewing it, so it is
    /// marked dismissed once you have read it there, and never waits on a Dismiss.
    public var isReviewedBySeeing: Bool { action == .openLogFile }

    public var level: StatusLevel {
        switch kind {
        case .problem: return dismissedAt == nil ? .problem : .muted
        case .done: return .ok
        case .info: return .neutral
        }
    }
}
