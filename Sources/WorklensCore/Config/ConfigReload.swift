import Foundation

/// What a reload attempt decided (#126).
///
/// A separate type because the ordering is the whole fix and a comment is not a guarantee.
/// `reloadConfig()` used to shut every service down and nil them *before* it read the new file,
/// so a single typo left a running app with no capture, no describe worker and no scheduler —
/// degraded until the next relaunch, over a value that was wrong for one second. Parsing is now
/// the first step and this is its answer: nothing is torn down until there is a `Config` in hand.
public enum ConfigReloadOutcome: Sendable, Equatable {
    /// It parsed. Tear the stack down and build it again around this.
    case rebuild(config: Config, provenance: ConfigProvenance)
    /// It did not. Nothing is stopped, nothing is cleared, capture carries on at the interval it
    /// already had — and this sentence, naming the key and the file, is what the user is told.
    case keepRunning(message: String, file: URL?)

    /// True when the running stack must be left exactly as it is.
    public var keepsRunning: Bool {
        if case .keepRunning = self { return true }
        return false
    }
}

/// The sentences and the decision behind "Reload configuration" and "Use defaults for these
/// keys and start" — in `WorklensCore` so both are tested without launching anything.
public enum ConfigReload {
    /// Runs `load` and decides. A throw can only ever produce `.keepRunning`.
    public static func outcome(
        of load: () throws -> (config: Config, provenance: ConfigProvenance)
    ) -> ConfigReloadOutcome {
        do {
            let loaded = try load()
            return .rebuild(config: loaded.config, provenance: loaded.provenance)
        } catch {
            return .keepRunning(message: failureMessage(error), file: (error as? ConfigError)?.file)
        }
    }

    /// `Configuration not reloaded — LOG_LEVEL: … (in /Users/you/.env)`. Says the count first
    /// when there is more than one, because "fix this and try again" is the wrong instruction
    /// when there are three things to fix.
    public static func failureMessage(_ error: Error) -> String {
        let sentences = (error as? ConfigError)?.sentences ?? ["\(error)"]
        let first = sentences.first ?? "\(error)"
        guard sentences.count > 1 else { return "Configuration not reloaded: \(first)" }
        return "Configuration not reloaded: \(sentences.count) settings need fixing. \(first)"
    }

    /// `Configuration reloaded — capturing every 30 s`.
    public static func reloadedMessage(_ config: Config) -> String {
        "Configuration reloaded: capturing every \(config.captureIntervalSeconds) s"
    }

    /// Whether a freshly rebuilt stack has to be stopped again to match the one it replaced.
    ///
    /// "It was not running" is ambiguous on its own, and getting it wrong is how a rebuild loses
    /// capture. Either the old stack was deliberately stopped — a reload must preserve that, or
    /// "Reload configuration" would silently start recording someone who had paused for a reason
    /// — or there was no old stack at all, because a degraded startup never built one. That
    /// second case is exactly what "Use defaults for these keys and start" exists to end, so it
    /// must leave the new stack running (#126).
    public static func stopsAfterRebuild(hadStack: Bool, wasRunning: Bool) -> Bool {
        hadStack && !wasRunning
    }

    /// What "use defaults for these keys and start" confirms. It names the keys it dropped and
    /// says the two things the user needs to know: this session only, and the file is untouched.
    public static func startedOnDefaultsMessage(droppedKeys: [String]) -> String {
        guard !droppedKeys.isEmpty else { return "Started with the configuration as it is." }
        return "Started with the built-in default for \(droppedKeys.joined(separator: ", ")): "
            + "this session only, and your file is unchanged."
    }

    // MARK: Scoping a reload (#135)

    /// The context keys, in registry order: the ones whose only reader is the context sync
    /// scheduler. Derived from `ConfigSection.context` so a key added there cannot be forgotten
    /// here — `ConfigReloadScopeTests` holds the two lists together.
    public static var contextKeyNames: [String] {
        Config.keys.filter { $0.section == .context }.map(\.name)
    }

    /// Whether a reload changed nothing but the context sources — a pasted Granola key, a new sync
    /// interval, a Google client id.
    ///
    /// It decides whether pressing Save in Settings → Integrations is allowed to stop capture.
    /// Until #135 every write rebuilt the whole stack: the screen capture scheduler, the describe
    /// worker and the timeline were all torn down and started again because a token was pasted,
    /// which lost the in-flight frame and re-armed every timer. When this answers true the app
    /// rebuilds only `contextSync`.
    ///
    /// Written as "the new config, with its context values put back, is the old config" rather
    /// than as a list of comparisons: a key added to `Config` outside the context section then
    /// makes this answer false — rebuild everything, the safe direction — instead of being
    /// silently ignored.
    public static func onlyContextChanged(from old: Config, to new: Config) -> Bool {
        guard old != new else { return false }
        var probe = new
        probe.contextSyncMinutes = old.contextSyncMinutes
        probe.granolaAPIKey = old.granolaAPIKey
        probe.googleClientID = old.googleClientID
        probe.googleClientSecret = old.googleClientSecret
        probe.googleTokenStore = old.googleTokenStore
        probe.githubShipped = old.githubShipped
        probe.memoRepos = old.memoRepos
        probe.agentSessions = old.agentSessions
        return probe == old
    }

    /// What a context-only reload says. It names the thing the user is most likely to be
    /// wondering about — that capture was left alone.
    public static func contextReloadedMessage(_ config: Config) -> String {
        "Integrations updated: syncing every \(config.contextSyncMinutes) min. Capture kept "
            + "running."
    }
}

public extension ConfigProvenance {
    /// Keys a lenient load dropped, in registry order — what `startOnDefaultsMessage` names.
    var keysUsingDefaults: [String] {
        warnings.compactMap { warning in
            if case let .usingDefault(key) = warning { return key }
            return nil
        }
    }
}
