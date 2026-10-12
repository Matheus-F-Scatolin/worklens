import Foundation

/// `.env.example`, generated from `Config.keys`.
///
/// The checked-in file is the output of this, byte for byte, and a test says so — which is how
/// an orphan section like the empty "--- Accessibility ---" block #87 left behind stops being
/// possible. `swift run Worklens config-example > .env.example` regenerates it.
public enum EnvExample {
    /// The width every `# --- Section ---…` rule is padded to.
    private static let ruleWidth = 77

    public static let preamble = """
        # Worklens configuration. Copy to .env and fill in the keys you need.
        #   cp .env.example .env
        # Every value below is the built-in default, so an empty .env is a valid .env.
        # Resolution order per key: process environment → $WORKLENS_ENV_FILE →
        # ~/Library/Application Support/Worklens/settings.json →
        # ~/Library/Application Support/Worklens/.env → ./.env → default.

        # Anything you put here is a secret: keep the real file at mode 600 and never commit it
        # (`.env` is git-ignored). `worklens config-dump` prints which of the layers above
        # supplied each value, so a surprising value has somewhere to be traced to.

        # An installed app needs none of this: with no .env anywhere it writes itself one at
        # ~/Library/Application Support/Worklens/.env on first launch and keeps its data in
        # ~/Library/Application Support/Worklens/data. `make install-env` is the developer step
        # that points it at a checkout instead, copying this file there with a relative DATA_DIR
        # pinned to this checkout on the way.

        # settings.json is the layer Worklens writes itself: Settings in the app, and
        # `worklens config set`. It outranks both .env files, so a setting you change in the app
        # wins over the same key typed here until `worklens config unset KEY` hands it back.

        # A `#` with a space before it starts a comment and the rest of the line is dropped, so
        # `CAPTURE_INTERVAL_SECONDS=60  # every minute` sets 60. A `#` with no space before it is
        # part of the value (a URL fragment, a regex), and quoting the whole value protects one
        # either way: PATTERN="secret #1".

        # This file is generated from the key registry (`Config.keys`):
        #   swift run Worklens config-example > .env.example
        """

    /// The whole file, ending in a newline.
    public static func render() -> String {
        var lines: [String] = preamble.components(separatedBy: "\n")
        for section in ConfigSection.allCases {
            let keys = Config.keys.filter { $0.section == section }
            // A section with no keys is the bug this generator exists to prevent, so it is a
            // programmer error rather than an empty block quietly shipped.
            guard !keys.isEmpty else {
                assertionFailure("ConfigSection.\(section) has no keys")
                continue
            }
            lines.append("")
            lines.append(rule(section.rawValue))
            for key in keys {
                lines += comment(key.docs)
                lines.append("\(key.name)=\(key.defaultLiteral)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func rule(_ title: String) -> String {
        let prefix = "# --- \(title) "
        let dashes = max(ruleWidth - prefix.count, 3)
        return prefix + String(repeating: "-", count: dashes)
    }

    /// `docs` as `# ` lines, with a bare `#` for the blank line inside a longer block.
    static func comment(_ docs: String) -> [String] {
        guard !docs.isEmpty else { return [] }
        return docs.components(separatedBy: "\n").map { $0.isEmpty ? "#" : "# \($0)" }
    }
}
