import Foundation

/// The `.env` Worklens writes for itself on a first run (#116).
///
/// `.env.example` lives in the repository; someone who installed the app rather than the
/// checkout has no copy of it, so the same content is generated from `Config.keys` here and
/// written to `~/Library/Application Support/Worklens/.env` the first time the app comes up
/// with no configuration file anywhere. Two differences from `EnvExample`:
///
/// - **Only the credentials are live lines.** Every other key is written commented out, at its
///   current default, so the file documents what can be set without freezing today's defaults
///   into a file that outlives them.
/// - **`DATA_DIR` is commented out like the rest**, which leaves the binary as the single source
///   of where data lives. `make install-env` is what points a bundled app at a checkout.
///
/// No SPM resources (`Bundle.module` is unreliable in a hand-built `.app`), so this is a Swift
/// constant like every other seed in the project.
public enum EnvTemplate {
    public static let preamble = """
        # Worklens configuration: written by Worklens itself on its first run.
        #
        # Fill in GEMINI_API_KEY below, the one Worklens needs to describe your screenshots,
        # then choose "Reload configuration" in the menu. Nothing else here has to change: every key that is not a credential is commented out at its built-in
        # default, so a line you delete gives you the default back rather than an empty value.
        #
        # This file is a secret: it is created at mode 600 and never leaves your Mac.
        # `worklens config-dump` prints which layer supplied each value, so a surprising value
        # has somewhere to be traced to.
        #
        # Your data lives in ~/Library/Application Support/Worklens/data unless DATA_DIR below
        # says otherwise. Settings you change in the app are written to settings.json beside
        # this file and outrank it.
        """

    /// The whole file, ending in a newline.
    public static let text: String = render()

    static func render() -> String {
        var lines: [String] = preamble.components(separatedBy: "\n")
        for section in ConfigSection.allCases {
            let keys = Config.keys.filter { $0.section == section }
            guard !keys.isEmpty else { continue }
            lines.append("")
            lines.append(EnvExample.rule(section.rawValue))
            for key in keys {
                lines += EnvExample.comment(key.docs)
                // A secret is the one thing the user has to type, so it is the one line left
                // live — and an empty value is "not set", so an untouched file changes nothing.
                lines.append(key.kind == .secret
                    ? "\(key.name)="
                    : "# \(key.name)=\(key.defaultLiteral)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
