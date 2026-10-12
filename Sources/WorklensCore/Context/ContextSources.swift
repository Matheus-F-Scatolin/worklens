import Foundation

/// The context sources this build knows about, in the order Settings → Integrations lists them.
///
/// One place so the CLI, the app and the tests never disagree about which sources exist. A new
/// source is one line here plus its file in `Context/Sources/`.
public enum ContextSources {
    public static func all(config: Config) -> [any ContextSyncSource] {
        // Granola's official API (#20). The local-cache reader `GRANOLA_MODE=local` used to
        // select is gone (#87): current Granola builds encrypt that cache.
        // Slack and Gmail were removed on 2026-09-23 (#285).
        var sources: [any ContextSyncSource] = [GranolaSource()]
        // Calendar, through one Google OAuth grant (#22).
        sources.append(CalendarSource(auth: GoogleAuth(config: config)))
        return sources
    }

    /// Only the ones whose credentials are present — what a sync round would actually touch.
    public static func configured(config: Config) -> [any ContextSyncSource] {
        all(config: config).filter { $0.isConfigured(config) }
    }
}
