import Foundation

/// The text `worklens config-dump` prints: every key with its resolved value, every secret
/// masked, and where each value came from.
///
/// It moved out of the CLI command in #156. `ConfigDumpCommand` prints what this returns,
/// character for character.
public enum ConfigDumpText {
    public static func render(config: Config, provenance: ConfigProvenance) -> String {
        var lines: [String] = []

        lines.append("layers, highest precedence first:")
        lines.append("  \(pad(ConfigLayer.process.label, 18))  the process environment")
        for file in provenance.files {
            lines.append("  \(pad(file.layer.label, 18))  \(file.url.path)\(file.exists ? "" : "   (missing)")")
        }
        lines.append("  \(pad(ConfigLayer.fallback.label, 18))  built into the binary")
        if provenance.noFilesFound {
            lines.append("no configuration file found; defaults in use")
        }
        lines.append("")

        let dump = config.dumpLines(provenance: provenance)
        let keyWidth = dump.map(\.key.count).max() ?? 0
        // Capped, not maxed: one very long DATA_DIR would otherwise open a gutter across
        // every other row. A value past the cap just pushes its own label right.
        let valueWidth = min(dump.map(\.value.count).max() ?? 0, 48)
        for line in dump {
            lines.append("\(pad(line.key, keyWidth))  \(pad(line.value, valueWidth))  (\(line.source.label))")
        }

        // #126: names only, never values — one of these could be a mistyped API key. Unknown
        // keys stay non-fatal (`docs/decisions.md`, #87): all this does is stop a typo like
        // CAPTURE_INTERVAL_SECS=30 from looking applied.
        if !provenance.unknownKeys.isEmpty {
            lines.append("")
            lines.append("warning: nothing reads these keys, check the spelling:")
            for unknown in provenance.unknownKeys {
                let suggestion = unknown.suggestion.map { " (did you mean \($0)?)" } ?? ""
                let place = unknown.url.map { " in \($0.path)" } ?? ""
                lines.append("         \(unknown.name)\(suggestion)\(place)")
            }
        }

        // Everything advisory the load found that is not about an unknown key: a model id that
        // is in no price-table row, a regex list written with commas.
        let otherWarnings = provenance.warnings.filter {
            if case .unknownKey = $0 { return false }
            return true
        }
        if !otherWarnings.isEmpty {
            lines.append("")
            for warning in otherWarnings {
                lines.append("warning: \(warning)")
            }
        }

        if !provenance.retiredKeys.isEmpty {
            lines.append("")
            lines.append("warning: these keys no longer do anything and can be deleted from your .env "
                + "files:")
            lines.append("         \(provenance.retiredKeys.joined(separator: ", "))")
        }

        if !config.allowNonLocalDataDir, let location = DataDirLocation.check(config.dataDir) {
            lines.append("")
            lines.append("warning: DATA_DIR is in \(location.provider): \(location.path).")
            lines.append("         Worklens will not capture into it: a file provider can sync the "
                + "SQLite write-ahead log")
            lines.append("         out from under an open database, and .lock is a kernel lock this Mac "
                + "cannot enforce")
            lines.append("         on another one. Move it to this Mac's own disk, or set "
                + "\(DataDirLocation.overrideKey)=true.")
        }

        guard !provenance.appSupportOverrides.isEmpty else {
            return lines.joined(separator: "\n")
        }
        let appSupport = provenance.files.first { $0.layer == .appSupport }?.url.path ?? "the App Support .env"
        lines.append("")
        lines.append("warning: \(appSupport) outranks this checkout's .env and disagrees with it about "
            + "\(provenance.appSupportOverrides.joined(separator: ", ")).")
        lines.append("         Set them in the process environment to win here, or re-run "
            + "`make install-env` from the checkout you want the bundled app to use.")
        return lines.joined(separator: "\n")
    }

    /// Left-aligned to at least `width`; `padding(toLength:)` truncates, which would hide a
    /// long path or a `DATA_DIR` that differs only in its tail.
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// One row per configuration key, for `config-dump --json`.
    ///
    /// The same `dumpLines` the text rendering walks, so the two cannot disagree about a value —
    /// and in particular the masking is the same, because it happens in `Config.dumpLines`
    /// rather than in either renderer. The warnings the text form ends with are deliberately
    /// left out: they are prose for a person.
    public struct Row: Codable, Equatable, Sendable {
        public let key: String
        public let value: String
        public let source: String
    }

    public static func rows(config: Config, provenance: ConfigProvenance) -> [Row] {
        config.dumpLines(provenance: provenance).map {
            Row(key: $0.key, value: $0.value, source: $0.source.label)
        }
    }
}
