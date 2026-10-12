import ArgumentParser
import Foundation
import WorklensCore

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the Worklens version, and which commit a bundled build is."
    )

    @OptionGroup var output: JSONOutputOptions

    /// `{version, commit, pr, builtAt, dirty}`. An unstamped build — what `swift run` produces —
    /// has a null for everything but `version` and `dirty`, so a script can tell the two apart
    /// without parsing the human line.
    ///
    /// The explicit `encode(to:)` is what keeps those nulls: the synthesised one writes optionals
    /// with `encodeIfPresent`, which would drop the key entirely and leave the shape changing
    /// under whoever is reading it.
    private struct Payload: Encodable {
        let version: String
        let commit: String?
        let pr: Int?
        let builtAt: Date?
        let dirty: Bool

        enum CodingKeys: String, CodingKey {
            case version, commit, pr, builtAt, dirty
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(commit, forKey: .commit)
            try container.encode(pr, forKey: .pr)
            try container.encode(builtAt, forKey: .builtAt)
            try container.encode(dirty, forKey: .dirty)
        }
    }

    func run() throws {
        let stamp = BuildStamp.current
        if output.json {
            print(try CLIOutput.jsonString(Payload(
                version: WorklensVersion.short,
                commit: stamp.commit,
                pr: stamp.pullRequest,
                builtAt: stamp.builtAt,
                dirty: stamp.dirty
            )))
            return
        }
        // The version on its own first line, so `worklens version | head -1` stays a bare version
        // number a script can compare (#130).
        print(WorklensVersion.short)
        // Only a bundle carries a stamp, so this line appears for
        // `build/Worklens.app/Contents/MacOS/Worklens version` and not for `swift run`.
        // `buildLine` rather than `menuLine`, which would repeat the version just printed.
        let build = stamp.buildLine()
        if !build.isEmpty { print(build) }
    }
}
